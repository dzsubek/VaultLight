import Foundation
import Testing

@testable import VaultLightCore

/// Spec 10 "VoiceOver labels on the search field and rows" (NOTES.md screen 1): what VoiceOver reads for a row, and
/// what the panel announces while focus stays in the search field.
@MainActor
@Suite("Spoken text")
struct SpokenTextTests {
    static let github = VaultEntry(
        id: "github", name: "GitHub", username: "octo", uris: ["https://github.com/login"], folderId: "work",
        hasTOTP: true)
    static let bare = VaultEntry(id: "bare", name: "Bare", username: "", uris: [])

    static func model() -> PanelViewModel {
        PanelViewModel(vault: FakePanelVault(entries: PanelViewModelTests.entries), system: RecordingPanelSystem())
    }

    @Test func rowReadsNameUsernameHostPlaceAndOneTimeCode() {
        let result = SearchResult(entry: Self.github, folderName: "Work", organizationName: nil, tier: .namePrefix)
        #expect(result.spokenDescription == "GitHub, octo, github.com, Work, has one-time code")
    }

    @Test func rowSkipsWhatTheItemDoesNotHave() {
        let result = SearchResult(entry: Self.bare, folderName: nil, organizationName: nil, tier: nil)
        #expect(result.spokenDescription == "Bare")
    }

    @Test func organizationIsReadInsteadOfTheFolder() {
        let result = SearchResult(
            entry: Self.github, folderName: "Work", organizationName: "Northwind Labs", tier: .namePrefix)
        #expect(result.spokenDescription == "GitHub, octo, github.com, Northwind Labs, has one-time code")
    }

    @Test func selectionIsAnnouncedAsItMoves() async {
        let model = Self.model()
        await model.setQuery("git")
        #expect(model.spokenSelection == "GitHub, octo, github.com, has one-time code")
        _ = await model.handle(.down)
        #expect(model.spokenSelection == "GitLab, lab, gitlab.com")
    }

    @Test func noMatchesIsAnnouncedWithTheQuery() async {
        let model = Self.model()
        await model.setQuery("  kubernetes ")
        #expect(model.spokenSelection == "No matches for “kubernetes”")
        await model.setQuery("")
        #expect(model.spokenSelection != nil)
        #expect(model.spokenSelection == model.selected?.spokenDescription)
    }
}
