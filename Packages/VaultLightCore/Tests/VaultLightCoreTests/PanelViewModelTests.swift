import Foundation
import Testing

@testable import VaultLightCore

@MainActor
@Suite("PanelViewModel")
struct PanelViewModelTests {
    static let entries = [
        VaultEntry(
            id: "github", name: "GitHub", username: "octo", uris: ["https://github.com/login"], favorite: true,
            hasTOTP: true),
        VaultEntry(id: "gitlab", name: "GitLab", username: "lab", uris: ["gitlab.com"]),
        VaultEntry(id: "bare", name: "Bare", username: nil, uris: []),
        VaultEntry(id: "bank", name: "Bank", username: "me", uris: ["https://bank.example"], favorite: true),
    ]

    let vault: FakePanelVault
    let system = RecordingPanelSystem()
    let model: PanelViewModel

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) {
        vault = FakePanelVault(
            entries: Self.entries,
            passwords: ["github": "pw-github", "gitlab": "pw-gitlab", "bank": "pw-bank"],
            codes: ["github": "123456"])
        model = PanelViewModel(vault: vault, system: system, sleep: sleep)
    }

    /// Types "git": GitHub then GitLab (both name prefixes, alphabetical), selection on row 0.
    func typeGit() async { await model.setQuery("git") }

    // MARK: Keys (spec 5.4)

    @Test func returnCopiesThePasswordAndCloses() async {
        await typeGit()
        let outcome = await model.handle(.returnKey)
        #expect(outcome == .close)
        #expect(system.secrets == ["pw-github"])
        #expect(await vault.passwordCalls == ["github"])
    }

    @Test func commandPCopiesThePasswordAndCloses() async {
        await typeGit()
        #expect(await model.handle(.copyPassword) == .close)
        #expect(system.secrets == ["pw-github"])
    }

    @Test func commandUCopiesTheUsernameAndStaysOpen() async {
        await typeGit()
        #expect(await model.handle(.copyUsername) == .stayOpen)
        #expect(system.usernames == ["octo"])
        #expect(system.secrets.isEmpty)
        #expect(model.footer == .usernameCopied)
    }

    @Test func commandTCopiesTheCodeAndCloses() async {
        await typeGit()
        #expect(await model.handle(.copyTOTP) == .close)
        #expect(system.secrets == ["123456"])
        #expect(await vault.totpCalls == ["github"])
    }

    @Test func commandOOpensThePrimaryURIAndCloses() async {
        await typeGit()
        #expect(await model.handle(.openURL) == .close)
        #expect(system.opened == [URL(string: "https://github.com/login")!])
    }

    @Test func escapeCloses() async {
        await typeGit()
        #expect(await model.handle(.escape) == .close)
        #expect(system.secrets.isEmpty && system.usernames.isEmpty && system.opened.isEmpty)
    }

    @Test func commandCommaClosesAndOpensSettings() async {
        #expect(await model.handle(.openSettings) == .closeAndOpenSettings)
    }

    // MARK: Navigation (spec 5.3)

    @Test func arrowsMoveTheSelectionAndClampAtBothEnds() async {
        await typeGit()
        #expect(model.results.count == 2)
        #expect(model.selectedIndex == 0)
        #expect(await model.handle(.up) == .stayOpen)
        #expect(model.selectedIndex == 0)
        _ = await model.handle(.down)
        #expect(model.selectedIndex == 1)
        #expect(model.selected?.entry.id == "gitlab")
        _ = await model.handle(.down)
        #expect(model.selectedIndex == 1)
        _ = await model.handle(.up)
        #expect(model.selectedIndex == 0)
    }

    @Test func selectionResetsToTheFirstRowWhenResultsChange() async {
        await typeGit()
        _ = await model.handle(.down)
        #expect(model.selectedIndex == 1)
        await model.setQuery("gitl")
        #expect(model.selectedIndex == 0)
        #expect(model.selected?.entry.id == "gitlab")
    }

    @Test func selectionIsNilWithoutResults() async {
        await model.setQuery("zzzz")
        #expect(model.results.isEmpty)
        #expect(model.selectedIndex == nil)
        #expect(model.selected == nil)
        #expect(!model.hasSelection)
        #expect(await model.handle(.down) == .stayOpen)
        #expect(model.selectedIndex == nil)
    }

    @Test func clickSelectsARow() async {
        await typeGit()
        model.select(index: 1)
        #expect(model.selectedIndex == 1)
        model.select(index: 9)
        #expect(model.selectedIndex == 1)
    }

    @Test func doubleClickActsAsReturn() async {
        await typeGit()
        let outcome = await model.activate(index: 1)
        #expect(outcome == .close)
        #expect(system.secrets == ["pw-gitlab"])
        #expect(model.selectedIndex == 1)
    }

    // MARK: Missing values and failures

    @Test func missingTOTPShowsTheFooterAndNeverCallsBW() async {
        await model.setQuery("gitlab")
        #expect(!model.isTOTPAvailable)
        #expect(await model.handle(.copyTOTP) == .stayOpen)
        #expect(model.footer == .noTOTP)
        #expect(model.footer.message == "No one-time code for this item")
        #expect(await vault.totpCalls.isEmpty)
        #expect(system.secrets.isEmpty)
    }

    @Test func missingPasswordShowsTheFooterAndStaysOpen() async {
        await model.setQuery("bare")
        #expect(await model.handle(.returnKey) == .stayOpen)
        #expect(model.footer == .noPassword)
        #expect(model.footer.message == "No password for this item")
        #expect(system.secrets.isEmpty)
        #expect(await vault.copies.isEmpty)
    }

    @Test func missingUsernameShowsTheFooter() async {
        await model.setQuery("bare")
        #expect(await model.handle(.copyUsername) == .stayOpen)
        #expect(model.footer == .noUsername)
        #expect(system.usernames.isEmpty)
    }

    @Test func missingURLShowsTheFooter() async {
        await model.setQuery("bare")
        #expect(await model.handle(.openURL) == .stayOpen)
        #expect(model.footer == .noURL)
        #expect(system.opened.isEmpty)
    }

    @Test func unsafeURLSchemeShowsTheFooter() async {
        let evil = VaultEntry(id: "evil", name: "Evil", uris: ["javascript:alert(1)"])
        let vault = FakePanelVault(entries: [evil])
        let model = PanelViewModel(vault: vault, system: system)
        await model.setQuery("evil")
        #expect(await model.handle(.openURL) == .stayOpen)
        #expect(model.footer == .noURL)
        #expect(system.opened.isEmpty)
    }

    @Test func failedFetchLeavesTheClipboardUntouchedAndShowsTheError() async {
        await vault.fail("github", with: .locked)
        await typeGit()
        #expect(await model.handle(.returnKey) == .stayOpen)
        #expect(model.footer == .locked)
        #expect(system.secrets.isEmpty)
        #expect(await vault.copies.isEmpty)
    }

    @Test func clipboardWriteFailureShowsClipboardWriteFailed() async {
        system.failsToCopy = true
        await typeGit()
        #expect(await model.handle(.returnKey) == .stayOpen)
        #expect(model.footer == .clipboardWriteFailed)
        #expect(model.footer.message == "Copy failed")
        #expect(await vault.copies.isEmpty)
    }

    @Test func usernameClipboardWriteFailureShowsClipboardWriteFailed() async {
        system.failsToCopy = true
        await typeGit()
        #expect(await model.handle(.copyUsername) == .stayOpen)
        #expect(model.footer == .clipboardWriteFailed)
        #expect(await vault.copies.isEmpty)
    }

    @Test func failedFetchOfUnknownKindKeepsTheClipboardUnchangedMessage() async {
        await vault.fail("github", with: .unknown("x"))
        await typeGit()
        #expect(await model.handle(.returnKey) == .stayOpen)
        #expect(model.footer == .copyFailed)
        #expect(model.footer.message == "Copy failed · clipboard unchanged")
        #expect(system.secrets.isEmpty)
    }

    @Test func timeoutShowsTheTimeoutMessage() async {
        await vault.fail("github", with: .timeout)
        await typeGit()
        #expect(await model.handle(.copyPassword) == .stayOpen)
        #expect(model.footer == .timedOut)
        #expect(model.footer.message == "bw didn't respond within 15 s")
    }

    @Test func unknownErrorTextNeverReachesTheFooter() async {
        await vault.fail("github", with: .unknown("secret stderr text"))
        await typeGit()
        #expect(await model.handle(.returnKey) == .stayOpen)
        #expect(model.footer == .copyFailed)
        #expect(model.footer.message?.contains("secret") == false)
    }

    @Test func footerMessagesAreFixedStrings() {
        #expect(PanelFooter.idle.message == nil)
        #expect(PanelFooter.noUsername.message == "No username for this item")
        #expect(PanelFooter.noURL.message == "No website for this item")
        #expect(PanelFooter.locked.message == "Vault is locked")
        #expect(PanelFooter.usernameCopied.message != nil)
        #expect(PanelFooter.passwordCopied.message != nil)
        #expect(PanelFooter.codeCopied.message != nil)
    }

    @Test func copyKeysWithNoResultsDoNothing() async {
        await model.setQuery("zzzz")
        for key in [PanelKey.returnKey, .copyPassword, .copyUsername, .copyTOTP, .openURL] {
            #expect(await model.handle(key) == .stayOpen)
        }
        let calls = await (vault.passwordCalls, vault.totpCalls)
        #expect(calls.0.isEmpty && calls.1.isEmpty)
        #expect(system.secrets.isEmpty && system.usernames.isEmpty && system.opened.isEmpty)
        #expect(model.footer == .idle)
    }

    @Test func recordCopyIsCalledOnSuccessOnly() async {
        await typeGit()
        _ = await model.handle(.copyUsername)
        _ = await model.handle(.returnKey)
        _ = await model.handle(.copyTOTP)
        #expect(await vault.copies == ["github", "github", "github"])
        _ = await model.handle(.down)
        _ = await model.handle(.copyTOTP)  // gitlab has no TOTP
        #expect(await vault.copies.count == 3)
    }

    // MARK: Username footer revert

    @Test func usernameFooterRevertsToIdle() async {
        await typeGit()
        _ = await model.handle(.copyUsername)
        #expect(model.footer == .usernameCopied)
        await model.waitForFooterRevert()
        #expect(model.footer == .idle)
    }

    @Test func aChangedFooterCancelsThePendingRevert() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let fixture = PanelViewModelTests(sleep: { _ in for await _ in stream { break } })
        await fixture.model.setQuery("gitlab")
        _ = await fixture.model.handle(.copyUsername)
        #expect(fixture.model.footer == .usernameCopied)
        await fixture.vault.fail("gitlab", with: .timeout)
        _ = await fixture.model.handle(.returnKey)
        #expect(fixture.model.footer == .timedOut)
        continuation.yield()
        await fixture.model.waitForFooterRevert()
        #expect(fixture.model.footer == .timedOut)
    }
}
