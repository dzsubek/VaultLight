import Foundation
import Testing

@testable import VaultLightCore

#if DEBUG
    private let isOptimizedBuild = false
#else
    private let isOptimizedBuild = true
#endif

/// Spec 10: keystroke to updated results ≤ 30 ms at 5,000 items. Runs in release mode only (`make perf`);
/// debug timings say nothing about the shipped app.
@Suite("SearchPerformance", .enabled(if: isOptimizedBuild))
struct SearchPerformanceTests {
    static let budget = Duration.milliseconds(30)

    /// What a user types, one keystroke at a time; each prefix is one search.
    static let typed = ["github", "aws console", "árvíz", "ghb", "server prod", "zzzz", "e", "tester@"]

    /// 5,000 deterministic entries with mixed names, usernames, hosts, folders and favorites.
    static func generatedEntries(count: Int = 5_000) -> [VaultEntry] {
        let words = [
            "GitHub", "GitLab", "AWS", "Console", "Árvíztűrő", "Bank", "Cloud", "Server", "Prod", "Staging",
            "Mail", "Router", "Docker", "Hub", "Netlify", "Postgres", "Hetzner", "Admin", "Office", "Wi-Fi",
        ]
        let tlds = ["com", "io", "net", "org", "example", "hu"]
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        return (0..<count).map { number in
            let name = (0..<(1 + next(3))).map { _ in words[next(words.count)] }.joined(separator: " ")
            let host = "\(words[next(words.count)].lowercased()).\(tlds[next(tlds.count)])"
            return VaultEntry(
                id: "item-\(number)", name: "\(name) \(number)", username: "user\(next(500))@example.com",
                uris: ["https://login.\(host)/path", "https://\(host)"], folderId: next(3) == 0 ? "f\(next(5))" : nil,
                organizationId: next(10) == 0 ? "o1" : nil, favorite: next(20) == 0, hasTOTP: next(4) == 0)
        }
    }

    @Test func everyKeystrokeSearchesFiveThousandItemsWithinBudget() {
        var index = SearchIndex(
            entries: Self.generatedEntries(),
            folders: (0..<5).map { VaultFolder(id: "f\($0)", name: "Folder \($0)") },
            organizations: [VaultOrganization(id: "o1", name: "Acme Ops")])
        _ = index.search("warm up")
        index.recordCopy(id: index.search("github").first?.id ?? "")

        let clock = ContinuousClock()
        var worst: (query: String, duration: Duration) = ("", .zero)
        for text in Self.typed {
            for length in 1...text.count {
                let query = String(text.prefix(length))
                var results: [SearchResult] = []
                let duration = clock.measure { results = index.search(query) }
                #expect(results.count <= SearchIndex.maxResults)
                if duration > worst.duration { worst = (query, duration) }
            }
        }
        print("slowest keystroke: \(worst.duration) for a \(worst.query.count)-character query")
        #expect(worst.duration <= Self.budget)
    }
}
