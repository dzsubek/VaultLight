import Foundation

@testable import VaultLightCore

/// `SessionStore` fake for unit tests: nothing reaches the Keychain. `readError` makes the next reads fail, as a
/// cancelled or failed Touch ID sheet would. `storedSessionOverride` makes `storedSession()` report what the real
/// Keychain does for a `.userPresence` item (`.dateUnknown`) while `readSession` still returns the real date, and
/// `storedSessionError` makes it throw.
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
    private var saveError: SessionStoreError?
    private var storedSessionOverride: StoredSession?
    private var storedSessionError: SessionStoreError?
    private var readHook: (@Sendable () async -> Void)?

    init(_ item: Item? = nil) {
        self.item = item
    }

    func setReadError(_ error: SessionStoreError?) {
        readError = error
    }

    func setDeleteError(_ error: SessionStoreError?) {
        deleteError = error
    }

    func setSaveError(_ error: SessionStoreError?) {
        saveError = error
    }

    /// Runs inside `readSession`, as the Touch ID sheet would: other calls can run while it suspends.
    func setReadHook(_ hook: (@Sendable () async -> Void)?) {
        readHook = hook
    }

    func setStoredSessionOverride(_ stored: StoredSession?) {
        storedSessionOverride = stored
    }

    func setStoredSessionError(_ error: SessionStoreError?) {
        storedSessionError = error
    }

    func storedSession() async throws -> StoredSession {
        if let storedSessionError { throw storedSessionError }
        if let storedSessionOverride { return storedSessionOverride }
        guard let item else { return .none }
        return .created(item.createdAt)
    }

    func readSession(reason: String) async throws -> StoredSessionRead {
        readReasons.append(reason)
        await readHook?()
        if let readError { throw readError }
        guard let item else { throw SessionStoreError.notFound }
        return StoredSessionRead(key: item.key, createdAt: item.createdAt)
    }

    func saveSession(_ key: SessionKey, createdAt: Date) async throws {
        if let saveError { throw saveError }
        item = Item(key: key, createdAt: createdAt)
    }

    func deleteSession() async throws {
        deleteCount += 1
        if let deleteError { throw deleteError }
        item = nil
    }
}
