import Foundation
import Testing
import os

@testable import VaultLightCore

/// A clock tests move by hand. Boot was an hour before the start.
final class TestClock: Sendable {
    static let start = Date(timeIntervalSince1970: 1_760_700_000)
    static let boot = start.addingTimeInterval(-3_600)

    private let state = OSAllocatedUnfairLock(initialState: (now: TestClock.start, idle: TimeInterval(0)))

    var now: Date { state.withLock { $0.now } }

    var sessionClock: SessionClock {
        SessionClock(
            now: { [state] in state.withLock { $0.now } }, bootTime: { TestClock.boot },
            idleTime: { [state] in state.withLock { $0.idle } })
    }

    func advance(by seconds: TimeInterval) { state.withLock { $0.now.addTimeInterval(seconds) } }
    func setIdle(_ seconds: TimeInterval) { state.withLock { $0.idle = seconds } }
}

/// Spec 3.4 and 3.5, against the fake `bw` and an in-memory store.
@Suite("SessionManager")
struct SessionManagerTests {
    private let fake: FakeBW
    private let clock = TestClock()

    init() throws {
        fake = try FakeBW()
        try fake.setState("locked")
    }

    private func manager(store: InMemorySessionStore, settings: SessionSettings = SessionSettings()) -> SessionManager {
        SessionManager(client: fake.client(), store: store, settings: settings, clock: clock.sessionClock)
    }

    private func storedItem(age: TimeInterval = 60, key: SessionKey = FakeBW.session) -> InMemorySessionStore.Item {
        InMemorySessionStore.Item(key: key, createdAt: clock.now.addingTimeInterval(-age))
    }

    /// A manager unlocked with the master password.
    private func unlockedManager(store: InMemorySessionStore = InMemorySessionStore()) async throws -> SessionManager {
        let manager = manager(store: store)
        #expect(try await manager.unlock(masterPassword: FakeBW.Defaults.masterPassword) == .unlocked)
        return manager
    }

    private func commands() throws -> [String] {
        try fake.calls().compactMap { ($0["argv"] as? [String])?.first }
    }

    /// Waits for a condition that another task makes true, failing after a minute.
    private func eventually(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met in time")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func expectLocked(_ manager: SessionManager) async throws {
        #expect(await !manager.isUnlocked)
        #expect(await manager.search("").isEmpty)
        #expect(await manager.search("git").isEmpty)
        let callsBefore = try fake.calls().count
        await #expect(throws: BWError.locked) { try await manager.password(for: FakeBW.Item.github) }
        #expect(try fake.calls().count == callsBefore)
    }

    // MARK: States (spec 3.1, 3.4)

    @Test func loggedOutNeedsOnboarding() async throws {
        try fake.setState("unauthenticated")
        #expect(try await manager(store: InMemorySessionStore()).refreshState() == .needsOnboarding)
    }

    @Test func lockedWithoutAStoredSessionNeedsTheMasterPassword() async throws {
        #expect(
            try await manager(store: InMemorySessionStore()).refreshState() == .needsMasterPassword(.noStoredSession))
    }

    @Test func validStoredSessionOffersTouchIDWithoutStartingBW() async throws {
        let manager = manager(store: InMemorySessionStore(storedItem()))
        #expect(try await manager.refreshState() == .storedSessionAvailable)
        #expect(try commands().isEmpty)
    }

    @Test func storedSessionPastItsMaximumAgeIsDeletedAndLocked() async throws {
        let store = InMemorySessionStore(storedItem(age: 7 * 86_400))
        let settings = SessionSettings(requireMasterPasswordAfterRestart: false)
        #expect(
            try await manager(store: store, settings: settings).refreshState()
                == .needsMasterPassword(.storedSessionExpired))
        #expect(await store.item == nil)
        #expect(try commands().contains("lock"))
    }

    @Test func storedSessionFromBeforeTheRestartIsDeletedAndLocked() async throws {
        let store = InMemorySessionStore(storedItem(age: 2 * 3_600))
        #expect(try await manager(store: store).refreshState() == .needsMasterPassword(.restarted))
        #expect(await store.item == nil)
        #expect(try commands().contains("lock"))
    }

    @Test func maximumAgeComesFromTheSettings() async throws {
        let store = InMemorySessionStore(storedItem(age: 2 * 86_400))
        let settings = SessionSettings(
            storedMaximumAge: .oneDay, requireMasterPasswordAfterRestart: false)
        #expect(
            try await manager(store: store, settings: settings).refreshState()
                == .needsMasterPassword(.storedSessionExpired))

        let kept = InMemorySessionStore(storedItem(age: 2 * 86_400))
        let manager = manager(store: kept, settings: SessionSettings(requireMasterPasswordAfterRestart: false))
        #expect(try await manager.refreshState() == .storedSessionAvailable)
    }

    @Test func unlockedSessionIsReadyWithoutStartingBW() async throws {
        let manager = try await unlockedManager()
        let callsBefore = try fake.calls().count
        #expect(try await manager.refreshState() == .unlocked)
        #expect(try fake.calls().count == callsBefore)
    }

    // MARK: Unlock

    @Test func masterPasswordUnlockStoresTheSessionAndBuildsTheIndex() async throws {
        let store = InMemorySessionStore()
        let manager = try await unlockedManager(store: store)
        #expect(await manager.isUnlocked)
        #expect(await store.item == InMemorySessionStore.Item(key: FakeBW.session, createdAt: clock.now))
        #expect(await manager.search("GitHub").first?.entry.name == "GitHub")
        #expect(try await manager.password(for: FakeBW.Item.github) == FakeBW.Item.githubPassword)
        #expect(try await manager.totp(for: FakeBW.Item.github) == FakeBW.Defaults.totpCode)
    }

    @Test func wrongMasterPasswordStoresNothing() async throws {
        let store = InMemorySessionStore()
        let manager = manager(store: store)
        await #expect(throws: BWError.invalidPassword) { try await manager.unlock(masterPassword: "wrong") }
        #expect(await store.item == nil)
        try await expectLocked(manager)
    }

    @Test func storedSessionUnlocksAfterUserPresence() async throws {
        try fake.setState("unlocked")
        let store = InMemorySessionStore(storedItem())
        let manager = manager(store: store)
        #expect(try await manager.unlockWithStoredSession(reason: "unlock VaultLight") == .unlocked)
        #expect(await store.readReasons == ["unlock VaultLight"])
        #expect(await manager.search("GitHub").first?.entry.name == "GitHub")
        // The stored session keeps its creation date, so its maximum age still counts from the master password.
        #expect(await store.item == storedItem())
    }

    @Test func cancelledTouchIDKeepsTheStoredSession() async throws {
        try fake.setState("unlocked")
        let store = InMemorySessionStore(storedItem())
        await store.setReadError(.cancelled)
        let manager = manager(store: store)
        await #expect(throws: SessionStoreError.cancelled) { try await manager.unlockWithStoredSession(reason: "r") }
        #expect(await store.item != nil)
        try await expectLocked(manager)
    }

    @Test func rejectedStoredSessionIsDeletedAndAsksForTheMasterPassword() async throws {
        try fake.setState("unlocked")
        let store = InMemorySessionStore(storedItem(key: SessionKey("stale-session-key")))
        let manager = manager(store: store)
        #expect(try await manager.unlockWithStoredSession(reason: "r") == .needsMasterPassword(.sessionRejected))
        #expect(await store.item == nil)
        try await expectLocked(manager)
    }

    @Test func storedSessionOfALoggedOutCLIIsDeleted() async throws {
        try fake.setState("unauthenticated")
        let store = InMemorySessionStore(storedItem())
        #expect(try await manager(store: store).unlockWithStoredSession(reason: "r") == .needsOnboarding)
        #expect(await store.item == nil)
    }

    @Test func expiredStoredSessionIsNotReadEvenWhenAsked() async throws {
        let store = InMemorySessionStore(storedItem(age: 30 * 86_400))
        let settings = SessionSettings(requireMasterPasswordAfterRestart: false)
        #expect(
            try await manager(store: store, settings: settings).unlockWithStoredSession(reason: "r")
                == .needsMasterPassword(.storedSessionExpired))
        #expect(await store.readReasons.isEmpty)
        #expect(await store.item == nil)
    }

    @Test func lockDuringUnlockWins() async throws {
        try fake.configure(["delay": ["list": 1]])
        let store = InMemorySessionStore()
        let manager = manager(store: store)
        let unlock = Task { try await manager.unlock(masterPassword: FakeBW.Defaults.masterPassword) }
        try await eventually { try commands().contains("list") }
        await manager.lockNow()
        #expect(try await unlock.value == .needsMasterPassword(.noStoredSession))
        #expect(await store.item == nil)
        try await expectLocked(manager)
    }

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

}

extension SessionManagerTests {
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
