import Foundation
import LocalAuthentication
import Security

/// The session key in one generic-password item of the data-protection keychain (spec 3.3):
/// `WhenUnlockedThisDeviceOnly`, behind `.userPresence`, never synced, with its creation date as a non-secret
/// attribute.
public struct KeychainSessionStore: SessionStore {
    public static let defaultService = "com.vaultlight.session"
    static let account = "bitwarden-session"
    static var protection: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
    static let accessFlags: SecAccessControlCreateFlags = .userPresence

    let service: String

    /// Tests pass `com.vaultlight.test` and never call the `SecItem` functions.
    public init(service: String = KeychainSessionStore.defaultService) {
        self.service = service
    }

    public func storedSessionDate() async throws -> Date? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributesQuery(context: LAContext()) as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.error(for: status) }
        return Self.creationDate(from: result as? [String: Any] ?? [:])
    }

    /// Evaluates user presence first, with the async LocalAuthentication API, then reads the item with that
    /// context. The system sheet shows once, and no thread blocks while it is up.
    public func readSession(reason: String) async throws -> SessionKey {
        guard try await storedSessionDate() != nil else { throw SessionStoreError.notFound }
        let context = LAContext()
        // The evaluated context authorizes reads until it is invalidated: limit it to this one.
        defer { context.invalidate() }
        context.localizedReason = reason
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw Self.error(for: error)
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(dataQuery(context: context) as CFDictionary, &result)
        guard status == errSecSuccess else { throw Self.error(for: status) }
        guard let data = result as? Data, let key = String(bytes: data, encoding: .utf8), !key.isEmpty else {
            throw SessionStoreError.unavailable(errSecDecode)
        }
        return SessionKey(key)
    }

    public func saveSession(_ key: SessionKey, createdAt: Date) async throws {
        try await deleteSession()
        let status = SecItemAdd(try addQuery(key: key, createdAt: createdAt) as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(for: status) }
    }

    public func deleteSession() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(for: status) }
    }

    // MARK: Queries

    func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func addQuery(key: SessionKey, createdAt: Date) throws -> [String: Any] {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(nil, Self.protection, Self.accessFlags, &error)
        else {
            _ = error?.takeRetainedValue()
            throw SessionStoreError.unavailable(errSecParam)
        }
        return baseQuery().merging(
            [
                kSecValueData as String: Data(key.rawValue.utf8),
                kSecAttrAccessControl as String: accessControl,
                kSecAttrSynchronizable as String: false,
                kSecAttrGeneric as String: Data(String(createdAt.timeIntervalSince1970).utf8),
                kSecAttrLabel as String: "VaultLight session",
            ]
        ) { _, new in new }
    }

    /// Attributes only. The context forbids interaction, so this can never show a prompt.
    func attributesQuery(context: LAContext) -> [String: Any] {
        context.interactionNotAllowed = true
        return baseQuery().merging(
            [
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context,
            ]
        ) { _, new in new }
    }

    func dataQuery(context: LAContext) -> [String: Any] {
        baseQuery().merging(
            [
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context,
            ]
        ) { _, new in new }
    }

    /// The stored creation date; `.distantPast` when it is missing or unreadable, so the item counts as expired.
    static func creationDate(from attributes: [String: Any]) -> Date {
        guard let data = attributes[kSecAttrGeneric as String] as? Data,
            let text = String(bytes: data, encoding: .utf8), let seconds = TimeInterval(text), seconds.isFinite
        else { return .distantPast }
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: Errors

    static func error(for status: OSStatus) -> SessionStoreError {
        switch status {
        case errSecItemNotFound: .notFound
        case errSecUserCanceled: .cancelled
        case errSecAuthFailed: .authenticationFailed
        default: .unavailable(status)
        }
    }

    static func error(for error: any Error) -> SessionStoreError {
        guard let error = error as? LAError else { return .unavailable(errSecNotAvailable) }
        switch error.code {
        case .userCancel, .appCancel, .systemCancel: return .cancelled
        case .authenticationFailed: return .authenticationFailed
        default: return .unavailable(errSecNotAvailable)
        }
    }
}
