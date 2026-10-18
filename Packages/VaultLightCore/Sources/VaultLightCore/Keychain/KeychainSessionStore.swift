import Foundation
import LocalAuthentication
import Security

/// The session key in one generic-password item of the data-protection keychain (spec 3.3):
/// `WhenUnlockedThisDeviceOnly`, behind `.userPresence`, never synced, with its creation date as a non-secret
/// attribute.
///
/// macOS refuses to return even the attributes of a `.userPresence` item without interaction
/// (`errSecInteractionNotAllowed`), so the silent query can't tell the age. A non-secret hint of the creation date
/// in `UserDefaults` lets an expired session be caught before any prompt; after user presence the date read with the
/// key is authoritative.
public struct KeychainSessionStore: SessionStore {
    public static let defaultService = "com.vaultlight.session"
    static let account = "bitwarden-session"
    static var protection: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
    static let accessFlags: SecAccessControlCreateFlags = .userPresence

    /// `UserDefaults` key of the creation-date hint: a `Double`, the date only, never the key.
    static let createdAtHintKey = "storedSessionCreatedAt"

    let service: String
    nonisolated(unsafe) let defaults: UserDefaults

    /// Tests pass `com.vaultlight.test` and a `UserDefaults` suite of their own, and never call the `SecItem`
    /// functions.
    public init(service: String = KeychainSessionStore.defaultService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    public func storedSession() async throws -> StoredSession {
        let context = LAContext()
        defer { context.invalidate() }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributesQuery(context: context) as CFDictionary, &result)
        return try storedSession(status: status, attributes: result as? [String: Any])
    }

    /// Evaluates user presence first, with the async LocalAuthentication API, then reads the item with that
    /// context. The system sheet shows once, and no thread blocks while it is up.
    public func readSession(reason: String) async throws -> StoredSessionRead {
        guard try await storedSession() != .none else { throw SessionStoreError.notFound }
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
        let status = SecItemCopyMatching(readQuery(context: context) as CFDictionary, &result)
        guard status == errSecSuccess else { throw Self.error(for: status) }
        return try Self.read(from: result as? [String: Any] ?? [:])
    }

    public func saveSession(_ key: SessionKey, createdAt: Date) async throws {
        try await deleteSession()
        let status = SecItemAdd(try addQuery(key: key, createdAt: createdAt) as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(for: status) }
        writeCreatedAtHint(createdAt)
    }

    public func deleteSession() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(for: status) }
        clearCreatedAtHint()
    }

    // MARK: Creation-date hint

    func writeCreatedAtHint(_ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.createdAtHintKey)
    }

    func clearCreatedAtHint() {
        defaults.removeObject(forKey: Self.createdAtHintKey)
    }

    func createdAtHint() -> Date? {
        guard let seconds = defaults.object(forKey: Self.createdAtHintKey) as? Double, seconds.isFinite else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Maps the status of the silent attributes query. A `.userPresence` item answers `errSecInteractionNotAllowed`
    /// even though the query only asks for attributes: the hint, if any, stands in for the date.
    func storedSession(status: OSStatus, attributes: [String: Any]?) throws -> StoredSession {
        switch status {
        case errSecSuccess: .created(Self.creationDate(from: attributes ?? [:]))
        case errSecItemNotFound: .none
        case errSecInteractionNotAllowed: createdAtHint().map { .created($0) } ?? .dateUnknown
        default: throw Self.error(for: status)
        }
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

    /// The key and the creation date in one query, with the context that already evaluated user presence.
    func readQuery(context: LAContext) -> [String: Any] {
        baseQuery().merging(
            [
                kSecReturnData as String: true,
                kSecReturnAttributes as String: true,
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

    /// The key and creation date of a read result; a missing date counts as expired.
    static func read(from attributes: [String: Any]) throws -> StoredSessionRead {
        guard let data = attributes[kSecValueData as String] as? Data, let key = String(bytes: data, encoding: .utf8),
            !key.isEmpty
        else { throw SessionStoreError.unavailable(errSecDecode) }
        return StoredSessionRead(key: SessionKey(key), createdAt: creationDate(from: attributes))
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
