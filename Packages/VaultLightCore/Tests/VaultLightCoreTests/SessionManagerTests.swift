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
///
/// Serialized: each test starts several fake `bw` processes, and the `python3` shim behind the fake is slow to start
/// on a loaded CI runner. Run in parallel, these tests pushed the timing tests in `ProcessRunnerTests` past their
/// budgets (CI run 39069818259).
@Suite("SessionManager", .serialized)
struct SessionManagerTests {
    let fake: FakeBW
    let clock = TestClock()

    init() throws {
        fake = try FakeBW()
        try fake.setState("locked")
    }

    func manager(
        store: InMemorySessionStore, settings: SessionSettings = SessionSettings(),
        policyCheckInterval: Duration = .seconds(3_600), backgroundSyncInterval: Duration? = nil
    ) -> SessionManager {
        SessionManager(
            client: fake.client(), store: store, settings: settings, clock: clock.sessionClock,
            backgroundSyncInterval: backgroundSyncInterval, policyCheckInterval: policyCheckInterval)
    }

    func storedItem(age: TimeInterval = 60, key: SessionKey = FakeBW.session) -> InMemorySessionStore.Item {
        InMemorySessionStore.Item(key: key, createdAt: clock.now.addingTimeInterval(-age))
    }

    /// A manager unlocked with the master password.
    func unlockedManager(store: InMemorySessionStore = InMemorySessionStore()) async throws -> SessionManager {
        let manager = manager(store: store)
        #expect(try await manager.unlock(masterPassword: FakeBW.Defaults.masterPassword) == .unlocked)
        return manager
    }

    func commands() throws -> [String] {
        try fake.calls().compactMap { ($0["argv"] as? [String])?.first }
    }

    func count(of command: String) throws -> Int {
        try commands().filter { $0 == command }.count
    }

    /// Waits for a condition that another task makes true, failing after two minutes (`FakeBW.patientTimeouts`).
    func eventually(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met in time")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func expectLocked(_ manager: SessionManager) async throws {
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
        let settings = SessionSettings(storedMaximumAge: .oneDay, requireMasterPasswordAfterRestart: false)
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
}
