import Foundation
import Testing

@testable import VaultLightCore

/// Spec 3.3 to 3.5: stored sessions whose date can't be read without user presence, and unreadable stores.
extension SessionManagerTests {
    // MARK: Date unknown until user presence (real Keychain: errSecInteractionNotAllowed)

    @Test func unknownStoredDateOffersTouchIDWithoutStartingBW() async throws {
        let store = InMemorySessionStore(storedItem(age: 30 * 86_400))
        await store.setStoredSessionOverride(.dateUnknown)
        #expect(try await manager(store: store).refreshState() == .storedSessionAvailable)
        #expect(try commands().isEmpty)
        #expect(await store.item != nil)
    }

    struct ExpiredCase: Sendable {
        let age: TimeInterval
        let restartRule: Bool
        let reason: MasterPasswordReason
    }

    @Test(arguments: [
        ExpiredCase(age: 7 * 86_400, restartRule: false, reason: .storedSessionExpired),
        ExpiredCase(age: 2 * 3_600, restartRule: true, reason: .restarted),
    ])
    func expiredDateAfterTouchIDDeletesTheItemLocksAndAsksForTheMasterPassword(
        _ expired: ExpiredCase
    ) async throws {
        try fake.setState("unlocked")
        let store = InMemorySessionStore(storedItem(age: expired.age))
        await store.setStoredSessionOverride(.dateUnknown)
        let settings = SessionSettings(requireMasterPasswordAfterRestart: expired.restartRule)
        let manager = manager(store: store, settings: settings)
        #expect(try await manager.unlockWithStoredSession(reason: "r") == .needsMasterPassword(expired.reason))
        #expect(await store.readReasons == ["r"])
        #expect(await store.item == nil)
        #expect(try commands().contains("lock"))
        try await expectLocked(manager)
    }

    @Test func validDateAfterTouchIDUnlocksAndCountsTheMaximumAgeFromIt() async throws {
        try fake.setState("unlocked")
        let settings = SessionSettings(
            storedMaximumAge: .oneDay, requireMasterPasswordAfterRestart: false, idleLock: .off)
        let store = InMemorySessionStore(storedItem(age: 23 * 3_600))
        await store.setStoredSessionOverride(.dateUnknown)
        let manager = manager(store: store, settings: settings)
        #expect(try await manager.unlockWithStoredSession(reason: "r") == .unlocked)
        clock.advance(by: 3_600 - 1)
        #expect(await manager.enforcePolicy())
        clock.advance(by: 1)
        #expect(await !manager.enforcePolicy())
    }

    @Test func unreadableStoreFallsBackToTheMasterPassword() async throws {
        let store = InMemorySessionStore(storedItem())
        await store.setStoredSessionError(.unavailable(-25_308))
        let manager = manager(store: store)
        #expect(try await manager.refreshState() == .needsMasterPassword(.noStoredSession))
        #expect(await store.deleteCount == 1)
        #expect(await store.item == nil)
        #expect(try commands().contains("lock"))
        #expect(try await manager.unlockWithStoredSession(reason: "r") == .needsMasterPassword(.noStoredSession))
        #expect(await store.readReasons.isEmpty)
    }

    @Test func freshHintDoesNotBeatAnExpiredItem() async throws {
        let store = InMemorySessionStore(storedItem(age: 8 * 86_400))
        await store.setStoredSessionOverride(.created(clock.now))
        let settings = SessionSettings(requireMasterPasswordAfterRestart: false)
        let manager = manager(store: store, settings: settings)
        #expect(try await manager.refreshState() == .storedSessionAvailable)
        #expect(
            try await manager.unlockWithStoredSession(reason: "r") == .needsMasterPassword(.storedSessionExpired))
        #expect(await store.item == nil)
        #expect(try commands().contains("lock"))
    }

    @Test func unlockDuringTheSheetIsNotUndoneByTheStaleStoredSession() async throws {
        let store = InMemorySessionStore(storedItem(age: 8 * 86_400))
        await store.setStoredSessionOverride(.dateUnknown)
        let settings = SessionSettings(requireMasterPasswordAfterRestart: false)
        let manager = manager(store: store, settings: settings)
        // While the sheet is up, the master password unlocks and stores a new session.
        await store.setReadHook {
            _ = try? await manager.unlock(masterPassword: FakeBW.Defaults.masterPassword)
        }
        #expect(try await manager.unlockWithStoredSession(reason: "r") == .unlocked)
        #expect(await manager.isUnlocked)
        #expect(await store.item == InMemorySessionStore.Item(key: FakeBW.session, createdAt: clock.now))
        #expect(try !commands().contains("lock"))
    }

    @Test func unreadableStoreStillNeedsOnboardingWhenTheCLIIsLoggedOut() async throws {
        try fake.setState("unauthenticated")
        let store = InMemorySessionStore(storedItem())
        await store.setStoredSessionError(.unavailable(-25_308))
        let manager = manager(store: store)
        #expect(try await manager.refreshState() == .needsOnboarding)
        #expect(try await manager.unlockWithStoredSession(reason: "r") == .needsOnboarding)
    }

    @Test func unreadableStoreFallbackSurvivesAFailingDelete() async throws {
        let store = InMemorySessionStore(storedItem())
        await store.setStoredSessionError(.unavailable(-25_308))
        await store.setDeleteError(.unavailable(-1))
        #expect(
            try await manager(store: store).refreshState() == .needsMasterPassword(.noStoredSession))
    }
}
