import Foundation
import Testing

@testable import VaultLightCore

@Suite("SearchIndex")
struct SearchIndexTests {
    /// The design's "git" example (NOTES.md Screen 2), one entry per ranking tier, in shuffled order.
    static let gitEntries = [
        entry("Digitec", host: "https://digitec.ch"),
        entry("Unrelated", host: "https://example.org"),
        entry("Gitpod", host: "https://gitpod.io"),
        entry("Forgejo", host: "https://git.home.arpa"),
        entry("My Git server", host: "https://code.example"),
        entry("GitHub", host: "https://github.com"),
        entry("Git", host: "https://git-scm.com"),
    ]

    static func entry(
        _ name: String, host: String? = nil, username: String? = nil, favorite: Bool = false,
        folderId: String? = nil, organizationId: String? = nil
    ) -> VaultEntry {
        VaultEntry(
            id: name, name: name, username: username, uris: host.map { [$0] } ?? [], folderId: folderId,
            organizationId: organizationId, favorite: favorite)
    }

    static func names(_ index: SearchIndex, _ query: String) -> [String] {
        index.search(query).map(\.entry.name)
    }

    @Test func tiersFollowTheSpecOrder() {
        let index = SearchIndex(entries: Self.gitEntries)
        // Exact, name prefix (alphabetical within the tier), word prefix, host, fuzzy.
        #expect(Self.names(index, "git") == ["Git", "GitHub", "Gitpod", "My Git server", "Forgejo", "Digitec"])
    }

    @Test func exactNameBeatsPrefix() {
        let index = SearchIndex(entries: [Self.entry("GitHub Enterprise"), Self.entry("GitHub")])
        #expect(Self.names(index, "github") == ["GitHub", "GitHub Enterprise"])
    }

    @Test func namePrefixBeatsWordPrefix() {
        let index = SearchIndex(entries: [Self.entry("Old Bank"), Self.entry("Banking")])
        #expect(Self.names(index, "bank") == ["Banking", "Old Bank"])
    }

    @Test func wordPrefixMatchesAfterAnyNonAlphanumeric() {
        let index = SearchIndex(entries: [Self.entry("Git server (self-hosted)")])
        #expect(index.search("hosted").first?.tier == .wordPrefix)
        #expect(index.search("self-host").first?.tier == .wordPrefix)
        #expect(index.search("server (self").first?.tier == .wordPrefix)
    }

    @Test func wordPrefixBeatsHost() {
        let index = SearchIndex(entries: [
            Self.entry("Example", host: "https://cloud.provider.example"), Self.entry("My Cloud"),
        ])
        #expect(Self.names(index, "cloud") == ["My Cloud", "Example"])
    }

    @Test func hostMatchesAtTheStartOfAnyLabel() {
        let index = SearchIndex(entries: [
            Self.entry("Mail", host: "https://accounts.google.com"),
            Self.entry("Hub", host: "https://hub.docker-registry.example"),
        ])
        #expect(index.search("google").map(\.tier) == [.host])
        #expect(index.search("accounts.goo").map(\.tier) == [.host])
        #expect(index.search("registry").map(\.tier) == [.host])
        // Inside a label is only a fuzzy match.
        #expect(index.search("oogle").map(\.tier) == [.fuzzy])
    }

    @Test func hostBeatsFuzzy() {
        let index = SearchIndex(entries: [Self.entry("Big Tree"), Self.entry("Repo", host: "https://bitbucket.org")])
        #expect(Self.names(index, "bit") == ["Repo", "Big Tree"])
        #expect(index.search("bit").map(\.tier) == [.host, .fuzzy])
    }

    @Test func fuzzyIsAnInOrderSubsequence() {
        let index = SearchIndex(entries: [Self.entry("Hetzner Cloud")])
        #expect(index.search("hzcld").map(\.tier) == [.fuzzy])
        #expect(index.search("h cloud").map(\.tier) == [.fuzzy])
        #expect(index.search("dlc").isEmpty)
    }

    @Test func usernamesAndHostsMatchFuzzily() {
        let index = SearchIndex(entries: [
            Self.entry("AWS Console", host: "https://signin.aws.amazon.com", username: "ops-admin")
        ])
        #expect(index.search("ops-admin").map(\.tier) == [.fuzzy])
        #expect(index.search("amzn").map(\.tier) == [.fuzzy])
    }

    @Test func caseAndDiacriticsAreIgnored() {
        let index = SearchIndex(entries: [Self.entry("Árvíztűrő Bank"), Self.entry("github")])
        #expect(index.search("arvizturo").map(\.tier) == [.namePrefix])
        #expect(index.search("ÁRVÍZ").map(\.tier) == [.namePrefix])
        #expect(index.search("ÁrVíZtŰrŐ bank").map(\.tier) == [.exact])
        #expect(index.search("GITHUB").map(\.tier) == [.exact])
        // Decomposed input (e + combining acute) folds the same way.
        #expect(index.search("A\u{0301}rv").map(\.tier) == [.namePrefix])
    }

    @Test func surroundingWhitespaceIsIgnored() {
        let index = SearchIndex(entries: Self.gitEntries)
        #expect(Self.names(index, "  git\n") == Self.names(index, "git"))
    }

    @Test func noMatchIsEmpty() {
        #expect(SearchIndex(entries: Self.gitEntries).search("zzz").isEmpty)
        #expect(SearchIndex().search("git").isEmpty)
    }

    @Test func copiedItemsRankFirstWithinTheirTier() {
        var index = SearchIndex(entries: Self.gitEntries)
        index.recordCopy(id: "GitHub")
        index.recordCopy(id: "Gitpod")
        index.recordCopy(id: "Digitec")
        // Most recent copy first inside the prefix tier; the boost never lifts an item over a better tier.
        #expect(Self.names(index, "git") == ["Git", "Gitpod", "GitHub", "My Git server", "Forgejo", "Digitec"])
        index.recordCopy(id: "GitHub")
        #expect(Self.names(index, "git").prefix(3) == ["Git", "GitHub", "Gitpod"])
    }

    @Test func emptyQueryShowsFavoritesWhenNothingWasCopied() {
        let index = SearchIndex(entries: [
            Self.entry("Zulu", favorite: true), Self.entry("Plain"), Self.entry("Alpha", favorite: true),
        ])
        #expect(Self.names(index, "") == ["Alpha", "Zulu"])
        #expect(Self.names(index, "   ") == ["Alpha", "Zulu"])
    }

    @Test func emptyQueryShowsRecentCopiesNewestFirst() {
        var index = SearchIndex(entries: [
            Self.entry("Zulu", favorite: true), Self.entry("Plain"), Self.entry("Other"),
        ])
        index.recordCopy(id: "Plain")
        index.recordCopy(id: "Other")
        index.recordCopy(id: "Plain")
        #expect(Self.names(index, "") == ["Plain", "Other"])
    }

    @Test func copiesOfUnknownIdsAreIgnored() {
        var index = SearchIndex(entries: [Self.entry("Alpha", favorite: true)])
        index.recordCopy(id: "missing")
        #expect(Self.names(index, "") == ["Alpha"])
    }

    @Test func resultsAreCappedAtFifty() {
        let many = (0..<120).map { Self.entry(String(format: "Item %03d", $0), favorite: true) }
        var index = SearchIndex(entries: many)
        #expect(SearchIndex.maxResults == 50)
        #expect(index.search("item").count == 50)
        #expect(index.search("item").first?.entry.name == "Item 000")
        #expect(index.search("").count == 50)
        for entry in many { index.recordCopy(id: entry.id) }
        #expect(index.search("").count == 50)
        #expect(index.search("").first?.entry.name == "Item 119")
    }

    @Test func resultsCarryFolderAndOrganizationNames() {
        let index = SearchIndex(
            entries: [
                Self.entry("Work item", folderId: "f1"), Self.entry("Shared item", organizationId: "o1"),
                Self.entry("Loose item"),
            ],
            folders: [VaultFolder(id: "f1", name: "Work"), VaultFolder(id: nil, name: "No Folder")],
            organizations: [VaultOrganization(id: "o1", name: "Acme Ops")])
        let results = Dictionary(uniqueKeysWithValues: index.search("item").map { ($0.entry.name, $0) })
        #expect(results["Work item"]?.folderName == "Work")
        #expect(results["Work item"]?.organizationName == nil)
        #expect(results["Shared item"]?.organizationName == "Acme Ops")
        #expect(results["Loose item"]?.folderName == nil)
    }

    @Test func rebuildKeepsTheBoostForItemsStillPresent() {
        var index = SearchIndex(entries: [Self.entry("Alpha"), Self.entry("Beta"), Self.entry("Gamma")])
        index.recordCopy(id: "Alpha")
        index.recordCopy(id: "Beta")
        index.replaceEntries([Self.entry("Alpha"), Self.entry("Gamma"), Self.entry("Delta", favorite: true)])
        #expect(Self.names(index, "") == ["Alpha"])
        #expect(Self.names(index, "delta") == ["Delta"])
        #expect(Self.names(index, "beta").isEmpty)
    }

    @Test func buildsFromTheFixtureVault() async throws {
        let fake = try FakeBW.unlocked()
        let client = fake.client()
        let listed: [VaultEntry.Listed] = try await client.listItems(session: FakeBW.session)
        let index = SearchIndex(
            entries: listed.compactMap(\.entry),
            folders: try await client.listFolders(session: FakeBW.session),
            organizations: try await client.listOrganizations(session: FakeBW.session))
        let results = index.search("git")
        #expect(results.prefix(3).map(\.entry.name) == ["Git server (self-hosted)", "GitHub", "GitLab"])
        #expect(results.first { $0.entry.name == "GitHub" }?.folderName == "Work")
        #expect(index.search("").map(\.entry.name) == ["GitHub", "Gmail"])
        #expect(index.search("recovery").isEmpty)
    }
}
