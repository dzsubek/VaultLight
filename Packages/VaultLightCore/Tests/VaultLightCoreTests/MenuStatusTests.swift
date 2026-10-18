import Foundation
import Testing

@testable import VaultLightCore

/// The menu-bar menu's first line and which commands work (spec 8, design 13).
@Suite struct MenuStatusTests {
    let now = Date(timeIntervalSince1970: 1_760_700_000)

    @Test func unlockedShowsTheAccountAndEnablesSyncAndLock() {
        let summary = VaultSummary(isUnlocked: true, email: "tester@example.com")
        let status = MenuStatus(state: .unlocked, summary: summary, now: now)
        #expect(status.title == "Unlocked")
        #expect(status.detail == "tester@example.com")
        #expect(status.canSync)
        #expect(status.canLock)
    }

    @Test func unlockedShowsHowLongAgoTheLastSyncWas() {
        let summary = VaultSummary(isUnlocked: true, email: "tester@example.com")
        let status = MenuStatus(
            state: .unlocked, summary: summary, lastSyncedAt: now.addingTimeInterval(-185), now: now)
        #expect(status.detail == "tester@example.com · synced 3 min ago")
        let fresh = MenuStatus(state: .unlocked, summary: VaultSummary(isUnlocked: true), lastSyncedAt: now, now: now)
        #expect(fresh.detail == "synced just now")
    }

    @Test func shortAgesForStatusLines() {
        #expect(RelativeTime.ago(30) == "just now")
        #expect(RelativeTime.ago(185) == "3 min ago")
        #expect(RelativeTime.ago(2 * 3_600 + 60) == "2 h ago")
        #expect(RelativeTime.ago(3 * 86_400) == "3 d ago")
    }

    @Test func aStillUnlockedSessionWinsOverAnOldState() {
        let status = MenuStatus(
            state: .needsMasterPassword(.noStoredSession), summary: VaultSummary(isUnlocked: true), now: now)
        #expect(status.title == "Unlocked")
        #expect(status.canLock)
    }

    @Test func lockedWithAStoredSessionSaysWhenItExpires() {
        let summary = VaultSummary(storedSessionExpiresAt: now.addingTimeInterval(6 * 86_400 + 600))
        let status = MenuStatus(state: .storedSessionAvailable, summary: summary, now: now)
        #expect(status.title == "Locked")
        #expect(status.detail == "Touch ID unlocks · session expires in 6 days")
        #expect(!status.canSync)
        #expect(!status.canLock)
        #expect(
            MenuStatus(state: .storedSessionAvailable, summary: VaultSummary(), now: now).detail == "Touch ID unlocks")
    }

    @Test func lockedWithoutAStoredSession() {
        let status = MenuStatus(state: .needsMasterPassword(.restarted), summary: VaultSummary(), now: now)
        #expect(status.title == "Locked")
        #expect(status.detail == "Master password required after restart")
        #expect(!status.canSync)
        #expect(!status.canLock)
    }

    @Test func loggedOut() {
        let status = MenuStatus(state: .needsOnboarding, summary: VaultSummary(), now: now)
        #expect(status.title == "Not signed in")
        #expect(status.detail == "Open VaultLight to set up")
        #expect(!status.canSync)
    }

    @Test func notCheckedYet() {
        let status = MenuStatus(state: nil, summary: VaultSummary(), now: now)
        #expect(status.title == "Locked")
        #expect(status.detail == nil)
        #expect(!status.canLock)
    }
}
