import Foundation
import Testing

@testable import VaultLightCore

/// Spec 3.5 and the session rows of spec 8. The policy is pure: every test passes the instants it decides on.
@Suite("SessionPolicy")
struct SessionPolicyTests {
    private static let now = Date(timeIntervalSince1970: 1_760_700_000)
    private static let bootedADayAgo = now.addingTimeInterval(-day)
    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 3_600
    private static let day: TimeInterval = 86_400

    @Test func defaultsMatchSpecSection8() {
        let settings = SessionSettings()
        #expect(settings.storedMaximumAge == .sevenDays)
        #expect(settings.requireMasterPasswordAfterRestart)
        #expect(settings.inMemoryLifetime == .eightHours)
        #expect(settings.idleLock == .fifteenMinutes)
    }

    @Test func optionsAreTheSpecValues() {
        #expect(
            SessionSettings.StoredMaximumAge.allCases.map(\.seconds) == [1 * Self.day, 7 * Self.day, 30 * Self.day])
        #expect(
            SessionSettings.InMemoryLifetime.allCases.map(\.seconds) == [15 * Self.minute, Self.hour, 8 * Self.hour])
        #expect(
            SessionSettings.IdleLock.allCases.map(\.seconds) == [
                nil, 5 * Self.minute, 15 * Self.minute, 30 * Self.minute,
            ])
    }

    // MARK: Stored session

    @Test(arguments: SessionSettings.StoredMaximumAge.allCases)
    func storedSessionExpiresAtItsMaximumAge(_ age: SessionSettings.StoredMaximumAge) {
        let policy = SessionPolicy(settings: SessionSettings(storedMaximumAge: age))
        let justInside = Self.now.addingTimeInterval(-age.seconds + 1)
        let atTheLimit = Self.now.addingTimeInterval(-age.seconds)
        #expect(policy.storedSession(createdAt: justInside, now: Self.now, bootTime: .distantPast) == .valid)
        #expect(policy.storedSession(createdAt: atTheLimit, now: Self.now, bootTime: .distantPast) == .expiredByAge)
    }

    @Test func storedSessionFromBeforeTheLastBootNeedsTheMasterPassword() {
        let policy = SessionPolicy(settings: SessionSettings())
        let beforeBoot = Self.bootedADayAgo.addingTimeInterval(-1)
        let afterBoot = Self.bootedADayAgo.addingTimeInterval(1)
        #expect(
            policy.storedSession(createdAt: beforeBoot, now: Self.now, bootTime: Self.bootedADayAgo)
                == .expiredByRestart)
        #expect(policy.storedSession(createdAt: afterBoot, now: Self.now, bootTime: Self.bootedADayAgo) == .valid)
    }

    @Test func restartRuleCanBeTurnedOff() {
        let policy = SessionPolicy(settings: SessionSettings(requireMasterPasswordAfterRestart: false))
        let beforeBoot = Self.bootedADayAgo.addingTimeInterval(-60)
        #expect(policy.storedSession(createdAt: beforeBoot, now: Self.now, bootTime: Self.bootedADayAgo) == .valid)
        #expect(policy.storedSession(createdAt: beforeBoot, now: Self.now, bootTime: nil) == .valid)
    }

    @Test func unknownBootTimeCountsAsARestart() {
        let policy = SessionPolicy(settings: SessionSettings())
        #expect(
            policy.storedSession(createdAt: Self.now.addingTimeInterval(-60), now: Self.now, bootTime: nil)
                == .expiredByRestart)
    }

    @Test func restartIsReportedBeforeAge() {
        let policy = SessionPolicy(settings: SessionSettings(storedMaximumAge: .oneDay))
        let old = Self.now.addingTimeInterval(-2 * Self.day)
        #expect(policy.storedSession(createdAt: old, now: Self.now, bootTime: Self.bootedADayAgo) == .expiredByRestart)
    }

    @Test func storedSessionFromTheFutureIsExpired() {
        let policy = SessionPolicy(settings: SessionSettings(requireMasterPasswordAfterRestart: false))
        #expect(
            policy.storedSession(createdAt: Self.now.addingTimeInterval(60), now: Self.now, bootTime: nil)
                == .expiredByAge)
    }

    // MARK: In-memory session

    @Test(arguments: SessionSettings.InMemoryLifetime.allCases)
    func inMemorySessionExpiresAfterItsLifetime(_ lifetime: SessionSettings.InMemoryLifetime) {
        let policy = SessionPolicy(settings: SessionSettings(inMemoryLifetime: lifetime, idleLock: .off))
        let justInside = Self.now.addingTimeInterval(-lifetime.seconds + 1)
        let atTheLimit = Self.now.addingTimeInterval(-lifetime.seconds)
        #expect(policy.inMemorySession(authenticatedAt: justInside, now: Self.now, idleTime: 0) == .valid)
        #expect(policy.inMemorySession(authenticatedAt: atTheLimit, now: Self.now, idleTime: 0) == .expiredByLifetime)
    }

    @Test(arguments: SessionSettings.IdleLock.allCases)
    func inMemorySessionExpiresAfterTheIdleLimit(_ idleLock: SessionSettings.IdleLock) {
        let policy = SessionPolicy(settings: SessionSettings(idleLock: idleLock))
        let recent = Self.now.addingTimeInterval(-10)
        guard let limit = idleLock.seconds else {
            #expect(policy.inMemorySession(authenticatedAt: recent, now: Self.now, idleTime: 7 * Self.hour) == .valid)
            return
        }
        #expect(policy.inMemorySession(authenticatedAt: recent, now: Self.now, idleTime: limit - 1) == .valid)
        #expect(policy.inMemorySession(authenticatedAt: recent, now: Self.now, idleTime: limit) == .expiredByIdle)
    }

    @Test func inMemorySessionFromTheFutureIsExpired() {
        let policy = SessionPolicy(settings: SessionSettings())
        #expect(
            policy.inMemorySession(authenticatedAt: Self.now.addingTimeInterval(60), now: Self.now, idleTime: 0)
                == .expiredByLifetime)
    }
}

@Suite("SessionClock")
struct SessionClockTests {
    @Test func systemBootTimeIsInThePast() throws {
        let boot = try #require(SessionClock.systemBootTime())
        #expect(boot < Date())
        #expect(boot > Date(timeIntervalSince1970: 1_500_000_000))
    }

    @Test func systemIdleTimeIsAvailable() {
        let idle = SessionClock.systemIdleTime()
        #expect(idle >= 0)
        #expect(idle.isFinite)
    }
}
