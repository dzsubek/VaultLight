import Foundation
import LocalAuthentication
import Security
import Testing

@testable import VaultLightCore

/// Spec 3.3. These tests inspect the queries `KeychainSessionStore` builds and how it maps statuses. None of them
/// calls `SecItem*`: the data-protection keychain needs the app's entitlement, and tests must never touch the user's
/// Keychain. The real store is checked by hand.
@Suite("KeychainSessionStore")
struct KeychainSessionStoreTests {
    private let store = KeychainSessionStore(service: "com.vaultlight.test")

    @Test func everyQueryTargetsTheOneItemInTheDataProtectionKeychain() throws {
        let context = LAContext()
        let queries = [
            store.baseQuery(), store.attributesQuery(context: context), store.dataQuery(context: context),
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

    @Test func dataQueryUsesTheEvaluatedContext() throws {
        let context = LAContext()
        let query = store.dataQuery(context: context)
        #expect(query[kSecReturnData as String] as? Bool == true)
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
