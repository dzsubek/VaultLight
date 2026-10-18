import Foundation
import Testing
import os

@testable import VaultLightCore

/// Spec 3.4, 10: every `bw` process costs seconds, so search is ready after `bw list items` alone.
/// Folder and organization names, and the account when it isn't known yet, follow in the background, and the sync
/// status says what runs (footer spinner).
extension SessionManagerTests {
    /// The `bw` commands so far, with their object for `list` and `get` ("list items"), in call order.
    func commandLines() throws -> [String] {
        try fake.calls().compactMap { call in
            guard let argv = call["argv"] as? [String], let verb = argv.first else { return nil }
            return ["list", "get"].contains(verb) && argv.count > 1 ? "\(verb) \(argv[1])" : verb
        }
    }

    @Test func storedSessionUnlockNeedsOnlyTheItemList() async throws {
        try fake.setState("unlocked")
        try fake.configure(["delay": ["folders": 1]])
        let manager = manager(store: InMemorySessionStore(storedItem()))
        #expect(try await manager.unlockWithStoredSession(reason: "r") == .unlocked)
        // A successful `bw list items` confirms the stored session (spec 3.4 step 4); no `bw status` before it.
        #expect(try commandLines().prefix(2) == ["--version", "list items"])
        #expect(await manager.search("GitHub").first?.entry.name == "GitHub")
    }

    @Test func masterPasswordUnlockNeedsOnlyTheItemList() async throws {
        try fake.configure(["delay": ["folders": 1]])
        let manager = manager(store: InMemorySessionStore())
        #expect(try await manager.unlock(masterPassword: FakeBW.Defaults.masterPassword) == .unlocked)
        #expect(try commandLines().prefix(2) == ["unlock", "list items"])
        #expect(await manager.search("GitHub").first?.entry.name == "GitHub")
    }

    @Test func folderAndOrganizationNamesArriveInTheBackground() async throws {
        try fake.setState("unlocked")
        let manager = manager(store: InMemorySessionStore(storedItem()))
        #expect(try await manager.unlockWithStoredSession(reason: "r") == .unlocked)
        try await eventually { await manager.search("GitHub").first?.folderName == "Work" }
        try await settled(manager)
        let lines = try commandLines()
        let firstSync = try #require(lines.firstIndex(of: "sync"))
        #expect(
            lines[..<firstSync].filter { $0.hasPrefix("list") } == ["list items", "list folders", "list organizations"])
    }

    @Test func theAccountIsAskedInTheBackgroundOnlyWhenUnknown() async throws {
        try fake.setState("unlocked")
        let manager = manager(store: InMemorySessionStore(storedItem()))
        #expect(try await manager.unlockWithStoredSession(reason: "r") == .unlocked)
        try await eventually { await manager.summary().email == FakeBW.Defaults.email }
        try await settled(manager)
        let lines = try commandLines()
        let status = try #require(lines.firstIndex(of: "status"))
        #expect(status > (lines.firstIndex(of: "list items") ?? .max))

        // Known now: the next unlock asks nothing but the lists.
        await manager.lockNow()
        let before = try commandLines().count
        #expect(try await manager.unlockWithStoredSession(reason: "r") == .unlocked)
        try await settled(manager, syncs: 2)
        #expect(!(try commandLines().dropFirst(before).contains("status")))
    }

    @Test func backgroundWorkIsShownInTheStatus() async throws {
        try fake.setState("unlocked")
        try fake.configure(["delay": ["folders": 1, "sync": 1]])
        let manager = manager(store: InMemorySessionStore(storedItem()))
        #expect(try await manager.unlockWithStoredSession(reason: "r") == .unlocked)
        try await eventually { await manager.syncStatus().activity == .loadingDetails }
        try await eventually { await manager.syncStatus().activity == .syncing }
        try await eventually { await manager.syncStatus().activity == nil }
        #expect(await manager.syncStatus().lastSyncedAt == clock.now)
    }

    @Test func aRejectedStoredSessionIsFoundByTheItemList() async throws {
        try fake.setState("unlocked")
        let store = InMemorySessionStore(storedItem(key: SessionKey("stale-session-key")))
        let manager = manager(store: store)
        #expect(try await manager.unlockWithStoredSession(reason: "r") == .needsMasterPassword(.sessionRejected))
        #expect(try commandLines() == ["--version", "list items"])
        #expect(await store.item == nil)
    }

    /// After the Touch ID sheet the item list still takes seconds: the panel learns when the key was read so it can
    /// say the vault is opening.
    @Test func touchIDUnlockSaysWhenTheKeyWasRead() async throws {
        try fake.setState("unlocked")
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let manager = manager(store: InMemorySessionStore(storedItem()))
        #expect(
            try await manager.unlockWithStoredSession(reason: "r", keyRead: { reads.withLock { $0 += 1 } }) == .unlocked
        )
        #expect(reads.withLock { $0 } == 1)

        let cancelled = InMemorySessionStore(storedItem())
        await cancelled.setReadError(.cancelled)
        await #expect(throws: SessionStoreError.cancelled) {
            try await self.manager(store: cancelled).unlockWithStoredSession(
                reason: "r", keyRead: { reads.withLock { $0 += 1 } })
        }
        #expect(reads.withLock { $0 } == 1)
    }
}
