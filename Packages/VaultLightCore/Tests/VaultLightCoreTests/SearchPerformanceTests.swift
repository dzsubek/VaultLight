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

    /// Spec 10: index build after unlock ≤ 3 s at 1,000 items. Most of that is `bw list items` itself (measured by
    /// hand); VaultLight's part, decoding the JSON and building the index, gets a tenth of it.
    static let indexBuildBudget = Duration.milliseconds(300)

    /// `bw list items` output for `entries`, with the secret fields the real output carries (spec 9.3), invented.
    static func listItemsJSON(_ entries: [VaultEntry]) throws -> Data {
        let items: [[String: Any]] = entries.enumerated().map { number, entry in
            [
                "object": "item", "id": entry.id, "type": 1, "name": entry.name, "favorite": entry.favorite,
                "folderId": entry.folderId as Any, "organizationId": entry.organizationId as Any, "reprompt": 0,
                "notes": "Invented note \(number) with a few words of text.",
                "fields": [["name": "PIN", "value": "\(number)", "type": 1]],
                "login": [
                    "username": entry.username as Any, "password": "invented-password-\(number)",
                    "totp": entry.hasTOTP ? "otpauth://totp/x?secret=INVENTED" : NSNull(),
                    "uris": entry.uris.map { ["match": NSNull(), "uri": $0] },
                ],
                "revisionDate": "2026-09-30T10:00:00.000Z", "collectionIds": [],
            ]
        }
        return try JSONSerialization.data(withJSONObject: items)
    }

    @Test func aThousandItemListingIsDecodedAndIndexedWithinBudget() throws {
        let data = try Self.listItemsJSON(Self.generatedEntries(count: 1_000))
        let clock = ContinuousClock()
        var slowest = Duration.zero
        for _ in 0..<5 {
            var index: SearchIndex?
            let duration = try clock.measure {
                let listed = try JSONDecoder().decode([VaultEntry.Listed].self, from: data)
                index = SearchIndex(entries: listed.compactMap(\.entry))
            }
            #expect(index?.count == 1_000)
            slowest = max(slowest, duration)
        }
        print("index build, 1,000 items (\(data.count / 1_024) KB of JSON): slowest \(slowest)")
        #expect(slowest <= Self.indexBuildBudget)
    }
}
