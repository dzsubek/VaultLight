import Foundation
import Testing

@testable import VaultLightCore

@MainActor
@Suite("PanelViewModel state")
struct PanelViewModelStateTests {
    let vault = FakePanelVault(
        entries: PanelViewModelTests.entries,
        passwords: ["github": "pw-github", "gitlab": "pw-gitlab", "bank": "pw-bank"],
        codes: ["github": "123456"])
    let system = RecordingPanelSystem()
    let model: PanelViewModel

    init() {
        model = PanelViewModel(vault: vault, system: system, sleep: { _ in })
    }

    func typeGit() async { await model.setQuery("git") }

    // MARK: Opening, sections, reset

    @Test func panelWillOpenClearsThePreviousQuery() async {
        await model.setQuery("bare")
        _ = await model.handle(.copyUsername)  // footer set, nothing copied
        #expect(model.footer == .noUsername)
        await model.panelWillOpen()
        #expect(model.query.isEmpty)
        #expect(model.footer == .idle)
        #expect(model.selectedIndex == 0)
        #expect(model.results.map(\.id).sorted() == ["bank", "github"])  // favorites
    }

    @Test func emptyQueryShowsFavoritesUntilSomethingIsCopied() async {
        await model.panelWillOpen()
        #expect(model.section == .favorites)
        await typeGit()
        #expect(model.section == nil)
        _ = await model.handle(.copyPassword)
        await model.panelWillOpen()
        #expect(model.section == .recent)
        #expect(model.results.map(\.id) == ["github"])
    }

    @Test func resetClearsEverything() async {
        await typeGit()
        _ = await model.handle(.copyPassword)
        model.reset()
        #expect(model.query.isEmpty)
        #expect(model.results.isEmpty)
        #expect(model.selectedIndex == nil)
        #expect(model.footer == .idle)
        #expect(model.section == nil)
    }

    @Test func aSecretFetchedAfterResetIsDropped() async {
        await typeGit()
        let action = Task { await model.handle(.returnKey) }
        model.reset()
        _ = await action.value
        #expect(system.secrets.isEmpty)
    }

    @Test func staleSearchResultsAreDropped() async {
        await vault.delay(query: "git", by: .milliseconds(200))
        let slow = Task { await model.setQuery("git") }
        try? await Task.sleep(for: .milliseconds(20))
        await model.setQuery("bank")
        await slow.value
        #expect(model.query == "bank")
        #expect(model.results.map(\.id) == ["bank"])
    }

    @Test func aSecondActionWhileOneIsInFlightIsIgnored() async {
        await typeGit()
        async let first = model.handle(.returnKey)
        async let second = model.handle(.returnKey)
        _ = await (first, second)
        #expect(await vault.passwordCalls.count == 1)
        #expect(system.secrets == ["pw-github"])
    }
}
