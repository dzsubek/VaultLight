import Foundation
import Testing

@testable import VaultLightCore

/// What the panel shows for each vault state (spec 3.1) and each error (spec 7.4). Fixed copy only.
@Suite struct PanelScreenTests {
    @Test func everyVaultStateHasItsScreen() {
        #expect(PanelScreen(.needsOnboarding) == .onboarding)
        #expect(PanelScreen(.needsMasterPassword(.noStoredSession)) == .masterPassword(.noStoredSession))
        #expect(PanelScreen(.storedSessionAvailable) == .touchID)
        #expect(PanelScreen(.unlocked) == .search)
    }

    @Test func missingBWShowsTheInstallInstructions() {
        let screen = PanelScreen(error: BWError.notInstalled)
        #expect(screen == .setupProblem(.notInstalled))
        let problem = SetupProblem.notInstalled
        #expect(problem.title == "Bitwarden CLI not found")
        #expect(problem.command == "brew install bitwarden-cli")
        #expect(problem.message.contains("Install it with Homebrew"))
        #expect(
            problem.detail(path: nil)
                == "Looked in /opt/homebrew/bin and /usr/local/bin. A custom path can be set in Settings.")
        #expect(
            problem.detail(path: "/Users/tester/bin/bw") == "Looked at /Users/tester/bin/bw. Change it in Settings.")
    }

    @Test func oldBWShowsTheUpgradePrompt() {
        let problem = SetupProblem.tooOld(installed: "2024.6.1")
        #expect(PanelScreen(error: BWError.tooOld(installed: "2024.6.1")) == .setupProblem(problem))
        #expect(problem.title == "Bitwarden CLI is out of date")
        #expect(problem.command == "brew upgrade bitwarden-cli")
        #expect(problem.message.contains("2025.1.0 or later"))
        #expect(problem.detail(path: "/opt/homebrew/bin/bw") == "Found bw 2024.6.1 at /opt/homebrew/bin/bw.")
    }

    @Test func unsafeBWIsRefusedWithoutAFixCommand() {
        let problem = SetupProblem.unsafeBinary
        #expect(PanelScreen(error: BWError.unsafeBinary) == .setupProblem(problem))
        #expect(problem.command == nil)
        #expect(problem.title == "Bitwarden CLI isn’t safe to use")
        #expect(problem.message.contains("Settings"))
    }

    @Test func loggedOutShowsOnboarding() {
        #expect(PanelScreen(error: BWError.unauthenticated) == .onboarding)
    }

    @Test func rejectedSessionAsksForTheMasterPassword() {
        #expect(PanelScreen(.needsMasterPassword(.sessionRejected)) == .masterPassword(.sessionRejected))
        #expect(PanelScreen(error: BWError.locked) == .masterPassword(.sessionRejected))
        #expect(MasterPasswordReason.sessionRejected.footer == "Stored session no longer works")
    }

    @Test func timeoutAndOtherFailuresHaveFixedCopy() {
        #expect(PanelScreen(error: BWError.timeout) == .failure(.timedOut))
        #expect(PanelScreen(error: BWError.network) == .failure(.offline))
        #expect(PanelScreen(error: BWError.unknown("secret item name")) == .failure(.unknown))
        #expect(PanelScreen(error: SessionStoreError.unavailable(-25_300)) == .failure(.unknown))
        #expect(PanelFailure.timedOut.message == PanelFooter.timedOut.message)
        for failure in [PanelFailure.timedOut, .offline, .unknown] {
            #expect(!failure.message.contains("secret"))
        }
    }

    @Test func masterPasswordReasonsMatchDesign07() {
        #expect(MasterPasswordReason.noStoredSession.footer == "Master password required")
        #expect(MasterPasswordReason.restarted.footer == "Master password required after restart")
        #expect(MasterPasswordReason.storedSessionExpired.footer == "Stored session expired")
        #expect(
            MasterPasswordReason.prompt(email: "tester@example.com")
                == "Enter the master password for tester@example.com.")
        #expect(MasterPasswordReason.prompt(email: nil) == "Enter your master password.")
    }

    @Test func syncFailuresBecomeFooterNotices() {
        #expect(SyncNotice(error: BWError.network) == .offline)
        #expect(SyncNotice(error: BWError.timeout) == .failed)
        #expect(SyncNotice(error: BWError.unknown("x")) == .failed)
        #expect(SyncNotice.offline.message == "Offline · showing the cached vault")
        #expect(SyncNotice.failed.message == "Sync failed")
    }

    @Test func relativeTimesForTheLockedScreens() {
        #expect(RelativeTime.duration(6 * 86_400 + 3_600) == "6 days")
        #expect(RelativeTime.duration(86_400) == "1 day")
        #expect(RelativeTime.duration(5 * 3_600 + 10) == "5 hours")
        #expect(RelativeTime.duration(3_600) == "1 hour")
        #expect(RelativeTime.duration(125) == "2 minutes")
        #expect(RelativeTime.duration(20) == "1 minute")
    }
}
