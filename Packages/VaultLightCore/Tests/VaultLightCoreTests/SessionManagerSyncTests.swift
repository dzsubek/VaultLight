import Foundation
import Testing

@testable import VaultLightCore

/// Spec 2.1 and 7.3: the index from the local cache first, then `bw sync` in the background, and the sync status the
/// footer, the menu and Settings show (design 08).
extension SessionManagerTests {
    /// `lastSync` in `bw status` format: 2026-10-17 08:00:00.123 UTC.
    static let earlierSync = (text: "2026-10-17T08:00:00.123Z", date: Date(timeIntervalSince1970: 1_792_224_000.123))

    /// Parsed dates differ from the literal in the last bits of the `Double`.
    static func isEarlierSync(_ date: Date?) -> Bool {
        date.map { abs($0.timeIntervalSince(earlierSync.date)) < 0.000_1 } ?? false
    }

    /// Waits until the sync after unlock has finished.
    func settled(_ manager: SessionManager, syncs: Int = 1) async throws {
        try await eventually {
            let status = await manager.syncStatus()
            return try count(of: "sync") >= syncs && !status.isSyncing
        }
    }

    @Test func unlockBuildsTheIndexFromTheCacheThenSyncs() async throws {
        try fake.configure(["delay": ["sync": 1]])
        let manager = try await unlockedManager()
        // Search works while `bw sync` is still running.
        #expect(await manager.search("GitHub").first?.entry.name == "GitHub")
        try await settled(manager)
        let all = try commands()
        let firstList = try #require(all.firstIndex(of: "list"))
        let sync = try #require(all.firstIndex(of: "sync"))
        #expect(firstList < sync)
        // The index is rebuilt after the sync (spec 2.1).
        #expect(all.suffix(4) == ["sync", "list", "list", "list"])
    }

    @Test func offStillSyncsOnceAfterUnlock() async throws {
        let manager = try await unlockedManager()
        try await settled(manager)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try count(of: "sync") == 1)
    }

    @Test func backgroundSyncRepeatsAtTheInterval() async throws {
        let manager = manager(store: InMemorySessionStore(), backgroundSyncInterval: .milliseconds(50))
        #expect(try await manager.unlock(masterPassword: FakeBW.Defaults.masterPassword) == .unlocked)
        try await settled(manager, syncs: 3)
    }

    @Test func intervalChangeReschedulesWithoutSyncingAtOnce() async throws {
        let manager = try await unlockedManager()
        try await settled(manager)
        await manager.setBackgroundSyncInterval(.seconds(3_600))
        try await Task.sleep(for: .milliseconds(300))
        #expect(try count(of: "sync") == 1)
        await manager.setBackgroundSyncInterval(.milliseconds(50))
        try await settled(manager, syncs: 2)
    }

    @Test func syncNowJoinsARunningSync() async throws {
        try fake.configure(["delay": ["sync": 1]])
        let manager = try await unlockedManager()
        try await eventually { await manager.syncStatus().isSyncing }
        try await manager.sync()
        #expect(try count(of: "sync") == 1)
        #expect(await manager.syncStatus().isSyncing == false)
    }

    @Test func lastSyncStartsFromBWStatus() async throws {
        try fake.configure(["last_sync": Self.earlierSync.text, "delay": ["sync": 1]])
        let manager = manager(store: InMemorySessionStore())
        #expect(try await manager.refreshState() == .needsMasterPassword(.noStoredSession))
        #expect(try await manager.unlock(masterPassword: FakeBW.Defaults.masterPassword) == .unlocked)
        let status = await manager.syncStatus()
        #expect(Self.isEarlierSync(status.lastSyncedAt))
        #expect(status.failure == nil)
    }

    @Test func successAndFailureArePublished() async throws {
        try fake.configure(["offline": true, "last_sync": Self.earlierSync.text])
        let manager = manager(store: InMemorySessionStore())
        _ = try await manager.refreshState()
        #expect(try await manager.unlock(masterPassword: FakeBW.Defaults.masterPassword) == .unlocked)
        try await settled(manager)
        let offline = await manager.syncStatus()
        #expect(offline.failure == .offline)
        // A failed sync keeps the time of the last good one.
        #expect(Self.isEarlierSync(offline.lastSyncedAt))

        try fake.configure(["fail": ["sync": "Something unexpected happened."]])
        await #expect(throws: BWError.self) { try await manager.sync() }
        #expect(await manager.syncStatus().failure == .failed)

        try fake.configure([:])
        clock.advance(by: 90)
        try await manager.sync()
        let synced = await manager.syncStatus()
        #expect(synced == SyncStatus(lastSyncedAt: clock.now, failure: nil, isSyncing: false))
        // The stream carries the latest status to its one listener.
        var updates = manager.syncStatusUpdates.makeAsyncIterator()
        #expect(await updates.next() == synced)
    }

    @Test func clearResetsTheSyncStatus() async throws {
        try fake.configure(["delay": ["sync": 1]])
        let manager = try await unlockedManager()
        try await eventually { await manager.syncStatus().isSyncing }
        await manager.lockNow()
        #expect(await manager.syncStatus() == SyncStatus())
        // The sync that was running finishes after the lock and publishes nothing.
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(await manager.syncStatus() == SyncStatus())
    }

    /// A lock while `bw sync` runs: the decrypted vault is never listed again for a session that is gone (spec 3.5,
    /// 9.1 "shortest practical time").
    @Test func aSyncCutShortByALockNeverListsTheVault() async throws {
        try fake.configure(["delay": ["sync": 1]])
        let manager = try await unlockedManager()
        try await eventually { await manager.syncStatus().isSyncing }
        let lists = try count(of: "list")
        await manager.lockNow()
        try await Task.sleep(for: .milliseconds(1_800))
        #expect(try count(of: "list") == lists)
    }

    /// Lock and forget waits for a Sync Now that is running, then runs `bw lock` last, with no listing in between.
    @Test func lockAndForgetWaitsForASyncNowToStop() async throws {
        let manager = try await unlockedManager()
        try await settled(manager)
        try fake.configure(["delay": ["sync": 1]])
        let syncNow = Task { try? await manager.sync() }
        try await eventually { await manager.syncStatus().isSyncing }
        try await manager.lockAndForget()
        await syncNow.value
        let all = try commands()
        #expect(all.last == "lock")
        let lastSync = try #require(all.lastIndex(of: "sync"))
        #expect(!all[lastSync...].contains("list"))
    }
}
