import Foundation
import Testing

@testable import VaultLightCore

/// Spec 3.5: what clears the in-memory session, Lock and forget, Sign out, background sync.
extension SessionManagerTests {
    // MARK: Clearing the in-memory session (spec 3.5)

    @Test(arguments: [SystemEvent.willSleep, .screenLocked, .sessionResigned])
    func systemEventsClearTheSessionButKeepTheStoredOne(_ event: SystemEvent) async throws {
        let store = InMemorySessionStore()
        let manager = try await unlockedManager(store: store)
        let (events, continuation) = AsyncStream.makeStream(of: SystemEvent.self)
        await manager.observe(events)
        continuation.yield(event)
        try await eventually { await !manager.isUnlocked }
        try await expectLocked(manager)
        #expect(await store.item != nil)
        #expect(try await manager.refreshState() == .storedSessionAvailable)
    }

    @Test func lockNowClearsTheSessionButKeepsTheStoredOne() async throws {
        let store = InMemorySessionStore()
        let manager = try await unlockedManager(store: store)
        await manager.lockNow()
        try await expectLocked(manager)
        #expect(await store.item != nil)
        #expect(try !commands().contains("lock"))
    }

    @Test(arguments: [SessionSettings.IdleLock.fiveMinutes, .fifteenMinutes, .thirtyMinutes])
    func idleTimeClearsTheSession(_ idleLock: SessionSettings.IdleLock) async throws {
        let limit = try #require(idleLock.seconds)
        let manager = try await unlockedManager()
        await manager.updateSettings(SessionSettings(idleLock: idleLock))
        clock.setIdle(limit - 1)
        #expect(await manager.enforcePolicy())
        #expect(await manager.isUnlocked)
        clock.setIdle(limit)
        #expect(await !manager.enforcePolicy())
        try await expectLocked(manager)
    }

    @Test func watchdogLocksAnIdleMacEvenIfTheHotkeyResetsTheIdleTime() async throws {
        let store = InMemorySessionStore()
        let manager = manager(store: store, policyCheckInterval: .milliseconds(20))
        _ = try await manager.unlock(masterPassword: FakeBW.Defaults.masterPassword)
        let cleared = Task { await manager.sessionCleared.first { _ in true } != nil }
        clock.setIdle(15 * 60)
        try await eventually { await !manager.isUnlocked }
        #expect(await cleared.value)
        // Pressing the hotkey is input: idle time is back to zero when the panel opens.
        clock.setIdle(0)
        #expect(try await manager.refreshState() == .storedSessionAvailable)
        try await expectLocked(manager)
    }

    @Test func watchdogEnforcesTheLifetimeWithoutAnyCall() async throws {
        let manager = manager(store: InMemorySessionStore(), policyCheckInterval: .milliseconds(20))
        _ = try await manager.unlock(masterPassword: FakeBW.Defaults.masterPassword)
        clock.advance(by: 8 * 3_600)
        try await eventually { await !manager.isUnlocked }
    }

    @Test func searchStopsOnceTheLifetimeIsOver() async throws {
        let manager = try await unlockedManager()
        clock.advance(by: 8 * 3_600)
        #expect(await manager.search("git").isEmpty)
        #expect(await !manager.isUnlocked)
    }

    @Test func storedSessionMaximumAgeAlsoEndsTheInMemorySession() async throws {
        try fake.setState("unlocked")
        let settings = SessionSettings(
            storedMaximumAge: .oneDay, requireMasterPasswordAfterRestart: false, idleLock: .off)
        let store = InMemorySessionStore(storedItem(age: 23 * 3_600))
        let manager = manager(store: store, settings: settings)
        #expect(try await manager.unlockWithStoredSession(reason: "r") == .unlocked)
        clock.advance(by: 3_600 - 1)
        #expect(await manager.enforcePolicy())
        clock.advance(by: 1)
        #expect(await !manager.enforcePolicy())
        #expect(try await manager.refreshState() == .needsMasterPassword(.storedSessionExpired))
        #expect(await store.item == nil)
    }

    @Test func idleLockCanBeTurnedOff() async throws {
        let manager = try await unlockedManager()
        await manager.updateSettings(SessionSettings(idleLock: .off))
        clock.setIdle(7 * 3_600)
        #expect(await manager.enforcePolicy())
    }

    @Test func inMemoryLifetimeClearsTheSession() async throws {
        let manager = try await unlockedManager()
        await manager.updateSettings(SessionSettings(inMemoryLifetime: .fifteenMinutes, idleLock: .off))
        clock.advance(by: 15 * 60 - 1)
        #expect(await manager.enforcePolicy())
        clock.advance(by: 1)
        #expect(await !manager.enforcePolicy())
        try await expectLocked(manager)
    }

    @Test func copyingChecksThePolicyFirst() async throws {
        let manager = try await unlockedManager()
        clock.setIdle(15 * 60)
        let callsBefore = try fake.calls().count
        await #expect(throws: BWError.locked) { try await manager.totp(for: FakeBW.Item.github) }
        #expect(try fake.calls().count == callsBefore)
        try await expectLocked(manager)
    }

    @Test func lockClearsTheCopyBoost() async throws {
        try fake.setState("unlocked")
        let manager = manager(store: InMemorySessionStore(storedItem()))
        _ = try await manager.unlockWithStoredSession(reason: "r")
        let favorites = await manager.search("").map(\.id)
        await manager.recordCopy(id: FakeBW.Item.gitlab)
        #expect(await manager.search("").map(\.id) == [FakeBW.Item.gitlab])
        await manager.lockNow()
        _ = try await manager.unlockWithStoredSession(reason: "r")
        #expect(await manager.search("").map(\.id) == favorites)
    }

    // MARK: Lock and forget, sign out

    @Test func lockAndForgetRunsBWLockAndDeletesTheStoredSession() async throws {
        let store = InMemorySessionStore()
        let manager = try await unlockedManager(store: store)
        try await manager.lockAndForget()
        try await expectLocked(manager)
        #expect(await store.item == nil)
        #expect(try commands().last == "lock")
        #expect(try await manager.refreshState() == .needsMasterPassword(.noStoredSession))
    }

    @Test func signOutClearsEverythingBeforeLoggingOut() async throws {
        let store = InMemorySessionStore()
        let manager = try await unlockedManager(store: store)
        await manager.setBackgroundSyncInterval(.milliseconds(50))
        try await eventually { try commands().filter { $0 == "sync" }.count >= 2 }

        #expect(try await manager.signOut() == .needsOnboarding)
        try await expectLocked(manager)
        #expect(await store.item == nil)
        #expect(try commands().last == "logout")

        // Background sync stopped: no sync after the logout.
        try await Task.sleep(for: .milliseconds(300))
        #expect(try commands().last == "logout")
        #expect(try await manager.refreshState() == .needsOnboarding)
    }

    @Test func failingLogoutStillLeavesNoUsableSession() async throws {
        let store = InMemorySessionStore()
        let manager = try await unlockedManager(store: store)
        try fake.configure(["fail": ["logout": "Logout failed."]])
        await #expect(throws: BWError.self) { try await manager.signOut() }
        try await expectLocked(manager)
        #expect(await store.item == nil)
        #expect(try await manager.refreshState() == .needsMasterPassword(.noStoredSession))
    }

    @Test func signOutLocksBWWhenNeitherDeleteNorLogoutWorked() async throws {
        let store = InMemorySessionStore()
        let manager = try await unlockedManager(store: store)
        await store.setDeleteError(.unavailable(-1))
        try fake.configure(["fail": ["logout": "Logout failed."]])
        await #expect(throws: (any Error).self) { try await manager.signOut() }
        try await expectLocked(manager)
        #expect(try commands().suffix(2) == ["logout", "lock"])
        // The key left in the store no longer opens the vault.
        await store.setDeleteError(nil)
        #expect(try await manager.unlockWithStoredSession(reason: "r") == .needsMasterPassword(.sessionRejected))
    }

    // MARK: Background sync

    @Test func backgroundSyncRunsWhileUnlockedAndStopsOnLock() async throws {
        let manager = try await unlockedManager()
        await manager.setBackgroundSyncInterval(.milliseconds(50))
        try await eventually { try commands().filter { $0 == "sync" }.count >= 2 }
        await manager.lockNow()
        // A sync that was already running may finish; none starts afterwards.
        try await Task.sleep(for: .milliseconds(200))
        let syncs = try commands().filter { $0 == "sync" }.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(try commands().filter { $0 == "sync" }.count == syncs)
    }

    @Test func syncRebuildsTheIndex() async throws {
        let manager = try await unlockedManager()
        try await manager.sync()
        #expect(try commands().suffix(4) == ["sync", "list", "list", "list"])
        #expect(await manager.search("GitHub").first?.entry.name == "GitHub")
    }
}
