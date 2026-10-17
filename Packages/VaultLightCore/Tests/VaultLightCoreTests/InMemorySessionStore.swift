import Foundation

@testable import VaultLightCore

/// `SessionStore` fake for unit tests: nothing reaches the Keychain. `readError` makes the next reads fail, as a
/// cancelled or failed Touch ID sheet would.
actor InMemorySessionStore: SessionStore {
    struct Item: Equatable {
        let key: SessionKey
        let createdAt: Date
    }

    private(set) var item: Item?
    private(set) var readReasons: [String] = []
    private(set) var deleteCount = 0
    private var readError: SessionStoreError?
    private var deleteError: SessionStoreError?

    init(_ item: Item? = nil) {
        self.item = item
    }

    func setReadError(_ error: SessionStoreError?) {
        readError = error
    }

    func setDeleteError(_ error: SessionStoreError?) {
        deleteError = error
    }

    func storedSessionDate() async throws -> Date? {
        item?.createdAt
    }

    func readSession(reason: String) async throws -> SessionKey {
        readReasons.append(reason)
        if let readError { throw readError }
        guard let item else { throw SessionStoreError.notFound }
        return item.key
    }

    func saveSession(_ key: SessionKey, createdAt: Date) async throws {
        item = Item(key: key, createdAt: createdAt)
    }

    func deleteSession() async throws {
        deleteCount += 1
        if let deleteError { throw deleteError }
        item = nil
    }
}
