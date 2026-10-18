import Foundation
import Testing

@testable import VaultLightCore

/// Keys and footer states that deal with `bw` taking seconds: Sync Now from the keyboard, and a copy in
/// progress.
extension PanelViewModelTests {
    /// ⌘R, and "Try again" after a failed sync (design 08), run Sync Now; the outcome reaches the footer through the
    /// sync status, so the panel stays open and the clipboard is untouched.
    @Test func commandRSyncsNowAndStaysOpen() async {
        await typeGit()
        #expect(await model.handle(.syncNow) == .stayOpen)
        #expect(await vault.syncCalls == 1)
        #expect(model.selectedIndex == 0)
        #expect(system.secrets.isEmpty && system.usernames.isEmpty && system.opened.isEmpty)
    }

    /// `bw get password` takes seconds: the footer says so until the copy lands.
    @Test func theFooterSaysAPasswordIsBeingFetched() async throws {
        await typeGit()
        await vault.holdSecrets()
        let copy = Task { await model.handle(.returnKey) }
        while await vault.passwordCalls.isEmpty { await Task.yield() }
        #expect(model.footer == .gettingPassword)
        await vault.releaseSecrets()
        #expect(await copy.value == .close)
        #expect(model.footer == .passwordCopied)
    }
}
