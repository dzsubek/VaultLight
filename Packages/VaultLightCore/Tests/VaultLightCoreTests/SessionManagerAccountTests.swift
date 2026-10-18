import Foundation
import Testing

@testable import VaultLightCore

/// What the panel, menu and Settings learn from `SessionManager` (spec 3.1, 7.4, design 06/07/12/13), against the
/// fake `bw`.
@Suite("SessionManager account", .serialized)
struct SessionManagerAccountTests {
    let fake: FakeBW
    let clock = TestClock()

    init() throws {
        fake = try FakeBW()
        try fake.setState("locked")
    }

    func manager(client: BWClient? = nil, store: InMemorySessionStore = InMemorySessionStore()) -> SessionManager {
        SessionManager(
            client: client ?? fake.client(), store: store, clock: clock.sessionClock,
            policyCheckInterval: .seconds(3_600))
    }

    func commands() throws -> [String] {
        try fake.calls().compactMap { ($0["argv"] as? [String])?.first }
    }

    @Test func missingBWIsReportedWithoutStartingAProcess() async throws {
        let client = BWClient(
            locator: BWLocator(candidates: ["/nonexistent/vaultlight/bw"], homebrewBinDirectories: []),
            dataDirectory: fake.dataDirectory, home: fake.dataDirectory.path)
        await #expect(throws: BWError.notInstalled) { try await manager(client: client).refreshState() }
        // Even with a stored session, the install instructions come before any Touch ID sheet (spec 3.1).
        let store = InMemorySessionStore(.init(key: FakeBW.session, createdAt: clock.now))
        await #expect(throws: BWError.notInstalled) {
            try await manager(client: client, store: store).refreshState()
        }
        #expect(try commands().isEmpty)
    }

    @Test func tooOldBWIsReportedWhenTheVaultIsLocked() async throws {
        try fake.configure(["version": "2024.6.1"])
        await #expect(throws: BWError.tooOld(installed: "2024.6.1")) { try await manager().refreshState() }
        try fake.configure([:])
        #expect(try await manager().refreshState() == .needsMasterPassword(.noStoredSession))
    }

    @Test func versionIsCheckedOncePerRunAfterItPasses() async throws {
        let manager = manager()
        _ = try await manager.refreshState()
        _ = try await manager.refreshState()
        #expect(try commands().filter { $0 == "--version" }.count == 1)
    }

    @Test func storedSessionIsOfferedBeforeAnyProcess() async throws {
        let store = InMemorySessionStore(.init(key: FakeBW.session, createdAt: clock.now.addingTimeInterval(-3_600)))
        let manager = manager(store: store)
        #expect(try await manager.refreshState() == .storedSessionAvailable)
        #expect(try commands().isEmpty)
        let summary = await manager.summary()
        #expect(summary.storedSessionExpiresAt == clock.now.addingTimeInterval(-3_600 + 7 * 86_400))
        #expect(!summary.isUnlocked)
    }

    @Test func lockedStateRemembersTheAccount() async throws {
        let manager = manager()
        _ = try await manager.refreshState()
        let summary = await manager.summary()
        #expect(summary.email == FakeBW.Defaults.email)
        #expect(summary.serverURL == "https://vault.bitwarden.com")
        #expect(summary.storedSessionExpiresAt == nil)
    }

    @Test func accountStatusAsksBW() async throws {
        let manager = manager()
        let status = try await manager.accountStatus()
        #expect(status.state == .locked)
        #expect(await manager.summary().email == FakeBW.Defaults.email)
    }

    @Test func unlockReportsEachStepAndTheLoginCount() async throws {
        let manager = manager()
        let steps = StepRecorder()
        #expect(
            try await manager.unlock(masterPassword: FakeBW.Defaults.masterPassword) { steps.append($0) } == .unlocked)
        let logins = await manager.search("").count
        #expect(steps.values.first == .vaultUnlocked)
        #expect(steps.values.contains(.sessionSaved(true)))
        guard case .indexBuilt(let count) = steps.values.last else {
            Issue.record("no index step")
            return
        }
        #expect(count > 0)
        #expect(count >= logins)
        let summary = await manager.summary()
        #expect(summary.isUnlocked)
        #expect(summary.loginCount == count)
        #expect(summary.storedSessionExpiresAt == clock.now.addingTimeInterval(7 * 86_400))
    }

    @Test func failedKeychainSaveIsReportedAndTheVaultStillUnlocks() async throws {
        let store = InMemorySessionStore()
        await store.setSaveError(.unavailable(-34_018))
        let steps = StepRecorder()
        let manager = manager(store: store)
        #expect(
            try await manager.unlock(masterPassword: FakeBW.Defaults.masterPassword) { steps.append($0) } == .unlocked)
        #expect(steps.values.contains(.sessionSaved(false)))
        #expect(await manager.summary().storedSessionExpiresAt == nil)
    }

    @Test func signOutForgetsTheAccount() async throws {
        let manager = manager()
        _ = try await manager.unlock(masterPassword: FakeBW.Defaults.masterPassword)
        _ = try await manager.accountStatus()
        #expect(try await manager.signOut() == .needsOnboarding)
        let summary = await manager.summary()
        #expect(summary.email == nil)
        #expect(summary.loginCount == nil)
        #expect(!summary.isUnlocked)
    }
}

/// Collects unlock steps from the progress callback.
final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [UnlockProgress] = []

    var values: [UnlockProgress] { lock.withLock { steps } }

    func append(_ step: UnlockProgress) {
        lock.withLock { steps.append(step) }
    }
}
