import Foundation
import LocalAuthentication
import Security
import Testing

@testable import VaultLightCore

/// Spec 3.3. These tests inspect the queries `KeychainSessionStore` builds and how it maps statuses. None of them
/// calls `SecItem*`: the data-protection keychain needs the app's entitlement, and tests must never touch the user's
/// Keychain. The real store is checked by hand.
@Suite("KeychainSessionStore")
final class KeychainSessionStoreTests {
    private let suiteName = "com.vaultlight.test.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let store: KeychainSessionStore

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        store = KeychainSessionStore(service: "com.vaultlight.test", defaults: defaults)
    }

    @Test func everyQueryTargetsTheOneItemInTheDataProtectionKeychain() throws {
        let context = LAContext()
        let queries = [
            store.baseQuery(), store.attributesQuery(context: context), store.readQuery(context: context),
            try store.addQuery(key: SessionKey("k"), createdAt: Date()),
        ]
        for query in queries {
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrService as String] as? String == "com.vaultlight.test")
            #expect(query[kSecAttrAccount as String] as? String == KeychainSessionStore.account)
            #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        }
    }

    @Test func productionServiceIsNotTheTestService() {
        #expect(KeychainSessionStore().service == KeychainSessionStore.defaultService)
        #expect(KeychainSessionStore.defaultService != "com.vaultlight.test")
    }

    @Test func itemIsThisDeviceOnlyBehindUserPresenceAndNeverSynced() throws {
        #expect(KeychainSessionStore.protection as String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(KeychainSessionStore.accessFlags == .userPresence)

        let query = try store.addQuery(key: SessionKey("k"), createdAt: Date())
        let accessControl = try #require(query[kSecAttrAccessControl as String])
        #expect(CFGetTypeID(accessControl as CFTypeRef) == SecAccessControlGetTypeID())
        // Accessibility lives inside the access control; setting it twice makes SecItemAdd fail.
        #expect(query[kSecAttrAccessible as String] == nil)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test func addQueryHoldsTheKeyAsDataAndTheCreationDateAsAnAttribute() throws {
        let created = Date(timeIntervalSince1970: 1_760_700_000.25)
        let query = try store.addQuery(key: SessionKey("session-value"), createdAt: created)
        #expect(query[kSecValueData as String] as? Data == Data("session-value".utf8))
        let attribute = try #require(query[kSecAttrGeneric as String] as? Data)
        #expect(KeychainSessionStore.creationDate(from: [kSecAttrGeneric as String: attribute]) == created)
        // The date attribute holds only the date.
        #expect(String(bytes: attribute, encoding: .utf8) == String(created.timeIntervalSince1970))
    }

    @Test func attributesQueryNeverAsksForTheSecretOrForUserInteraction() throws {
        let context = LAContext()
        let query = store.attributesQuery(context: context)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect(query[kSecReturnData as String] == nil)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect((query[kSecUseAuthenticationContext as String] as? LAContext) === context)
        #expect(context.interactionNotAllowed)
    }

    @Test func readQueryAsksForDataAndAttributesWithTheEvaluatedContext() throws {
        let context = LAContext()
        let query = store.readQuery(context: context)
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect((query[kSecUseAuthenticationContext as String] as? LAContext) === context)
    }

    @Test func missingOrUnreadableCreationDateCountsAsExpired() {
        #expect(KeychainSessionStore.creationDate(from: [:]) == .distantPast)
        #expect(
            KeychainSessionStore.creationDate(from: [kSecAttrGeneric as String: Data("not a date".utf8)])
                == .distantPast)
        #expect(KeychainSessionStore.creationDate(from: [kSecAttrGeneric as String: "1760700000"]) == .distantPast)
    }

    @Test func readResultHoldsTheKeyAndTheCreationDate() throws {
        let created = Date(timeIntervalSince1970: 1_760_700_000.25)
        let attributes: [String: Any] = [
            kSecValueData as String: Data("session-value".utf8),
            kSecAttrGeneric as String: Data(String(created.timeIntervalSince1970).utf8),
        ]
        let read = try KeychainSessionStore.read(from: attributes)
        #expect(read.key == SessionKey("session-value"))
        #expect(read.createdAt == created)
        // No date counts as expired; no key is an error.
        let undated = try KeychainSessionStore.read(from: [kSecValueData as String: Data("k".utf8)])
        #expect(undated.createdAt == .distantPast)
        #expect(throws: SessionStoreError.unavailable(errSecDecode)) {
            try KeychainSessionStore.read(from: [kSecAttrGeneric as String: Data("1".utf8)])
        }
    }

    // MARK: Silent attributes read (errSecInteractionNotAllowed for a .userPresence item)

    @Test func silentReadMapsSuccessToTheCreationDate() throws {
        let created = Date(timeIntervalSince1970: 1_760_700_000)
        let attributes: [String: Any] = [kSecAttrGeneric as String: Data(String(1_760_700_000.0).utf8)]
        #expect(try store.storedSession(status: errSecSuccess, attributes: attributes) == .created(created))
        #expect(try store.storedSession(status: errSecSuccess, attributes: [:]) == .created(.distantPast))
    }

    @Test func silentReadMapsNotFoundToNone() throws {
        #expect(try store.storedSession(status: errSecItemNotFound, attributes: nil) == .none)
    }

    @Test func interactionNotAllowedMapsToDateUnknownWithoutAHint() throws {
        #expect(try store.storedSession(status: errSecInteractionNotAllowed, attributes: nil) == .dateUnknown)
    }

    @Test func interactionNotAllowedMapsToTheHintWhenThereIsOne() throws {
        let created = Date(timeIntervalSince1970: 1_760_700_000.5)
        store.writeCreatedAtHint(created)
        #expect(try store.storedSession(status: errSecInteractionNotAllowed, attributes: nil) == .created(created))
    }

    @Test func otherSilentReadFailuresStillThrow() {
        #expect(throws: SessionStoreError.unavailable(errSecMissingEntitlement)) {
            try store.storedSession(status: errSecMissingEntitlement, attributes: nil)
        }
        #expect(throws: SessionStoreError.cancelled) {
            try store.storedSession(status: errSecUserCanceled, attributes: nil)
        }
    }

    // MARK: Creation-date hint

    @Test func hintHoldsOnlyTheCreationDateAsADouble() throws {
        let created = Date(timeIntervalSince1970: 1_760_700_000.5)
        store.writeCreatedAtHint(created)
        let stored = defaults.dictionaryRepresentation().filter { $0.key == KeychainSessionStore.createdAtHintKey }
        #expect(KeychainSessionStore.createdAtHintKey == "storedSessionCreatedAt")
        #expect(stored.count == 1)
        #expect(stored[KeychainSessionStore.createdAtHintKey] as? Double == created.timeIntervalSince1970)
        #expect(store.createdAtHint() == created)
    }

    @Test func clearingTheHintRemovesIt() {
        store.writeCreatedAtHint(Date(timeIntervalSince1970: 1_760_700_000))
        store.clearCreatedAtHint()
        #expect(store.createdAtHint() == nil)
        #expect(defaults.object(forKey: KeychainSessionStore.createdAtHintKey) == nil)
    }

    @Test func unusableHintCountsAsMissing() {
        defaults.set("not a number", forKey: KeychainSessionStore.createdAtHintKey)
        #expect(store.createdAtHint() == nil)
        defaults.set(Double.nan, forKey: KeychainSessionStore.createdAtHintKey)
        #expect(store.createdAtHint() == nil)
    }

    @Test func statusesMapToTypedErrors() {
        #expect(KeychainSessionStore.error(for: errSecItemNotFound) == .notFound)
        #expect(KeychainSessionStore.error(for: errSecUserCanceled) == .cancelled)
        #expect(KeychainSessionStore.error(for: errSecAuthFailed) == .authenticationFailed)
        #expect(
            KeychainSessionStore.error(for: errSecInteractionNotAllowed) == .unavailable(errSecInteractionNotAllowed))
        #expect(KeychainSessionStore.error(for: errSecMissingEntitlement) == .unavailable(errSecMissingEntitlement))
    }

    @Test func authenticationErrorsMapToTypedErrors() {
        for code in [LAError.userCancel, .appCancel, .systemCancel] {
            #expect(KeychainSessionStore.error(for: LAError(code)) == .cancelled)
        }
        #expect(KeychainSessionStore.error(for: LAError(.authenticationFailed)) == .authenticationFailed)
        #expect(KeychainSessionStore.error(for: LAError(.passcodeNotSet)) == .unavailable(errSecNotAvailable))
    }
}
