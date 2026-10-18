import Foundation
import Testing

@testable import VaultLightCore

/// "Try again" after a failed copy or a timeout (design 16 footer, spec 7.4 "action can be retried").
@MainActor
@Suite("PanelViewModel retry")
struct PanelViewModelRetryTests {
    let vault = FakePanelVault(
        entries: PanelViewModelTests.entries, passwords: ["github": "pw-github", "gitlab": "pw-gitlab"],
        codes: ["github": "123456"])
    let system = RecordingPanelSystem()
    let model: PanelViewModel

    init() {
        model = PanelViewModel(vault: vault, system: system, sleep: { _ in })
    }

    private func typeGit() async {
        await model.setQuery("git")
    }

    @Test func nothingToRetryAtFirst() async {
        await typeGit()
        #expect(!model.canRetry)
        #expect(await model.retry() == .stayOpen)
        #expect(system.secrets.isEmpty)
    }

    @Test func tryAgainRepeatsATimedOutCopy() async {
        await vault.fail("github", with: .timeout)
        await typeGit()
        #expect(await model.handle(.copyTOTP) == .stayOpen)
        #expect(model.footer == .timedOut)
        #expect(model.canRetry)
        await vault.fail("github", with: nil)
        #expect(await model.retry() == .close)
        #expect(system.secrets == ["123456"])
        #expect(model.footer == .codeCopied)
        #expect(!model.canRetry)
    }

    @Test func returnRepeatsTheFailedActionNotThePasswordCopy() async {
        await vault.fail("github", with: .unknown("x"))
        await typeGit()
        _ = await model.handle(.copyTOTP)
        #expect(model.footer == .copyFailed)
        await vault.fail("github", with: nil)
        #expect(await model.handle(.returnKey) == .close)
        #expect(system.secrets == ["123456"])
        #expect(await vault.passwordCalls.isEmpty)
    }

    @Test func movingTheSelectionDropsTheRetry() async {
        await vault.fail("github", with: .timeout)
        await typeGit()
        _ = await model.handle(.copyPassword)
        #expect(model.canRetry)
        _ = await model.handle(.down)
        #expect(!model.canRetry)
        #expect(model.footer == .idle)
        #expect(await model.handle(.returnKey) == .close)
        #expect(system.secrets == ["pw-gitlab"])
    }

    @Test func aMissingValueIsNotRetried() async {
        await typeGit()
        _ = await model.handle(.down)
        _ = await model.handle(.copyTOTP)
        #expect(model.footer == .noTOTP)
        #expect(!model.canRetry)
    }

    @Test func resetDropsTheRetry() async {
        await vault.fail("github", with: .timeout)
        await typeGit()
        _ = await model.handle(.copyPassword)
        model.reset()
        #expect(!model.canRetry)
    }
}
