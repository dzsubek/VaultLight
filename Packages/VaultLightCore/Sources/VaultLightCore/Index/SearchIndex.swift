/// How a result matched the query, best first (spec 5.1 ranking order).
public enum MatchTier: Int, Sendable {
    case exact
    case namePrefix
    case wordPrefix
    case host
    /// The query's letters appear in order in the name, a username or a host.
    case fuzzy
}

/// One result row's data (spec 5.2).
public struct SearchResult: Sendable, Equatable, Identifiable {
    public let entry: VaultEntry
    public let folderName: String?
    public let organizationName: String?
    /// `nil` for the empty-query list of recent copies or favorites.
    public let tier: MatchTier?

    public var id: String { entry.id }
}

/// Only the id and tier, for the same reason as `VaultEntry`'s description.
extension SearchResult: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "SearchResult(id: \(id), tier: \(tier.map { "\($0)" } ?? "none"))" }
    public var debugDescription: String { description }
}

/// The in-memory search index (spec 2.1, 5.1): login metadata only, plus this session's copy history.
///
/// Searching never starts a process. The owner discards the whole value on lock, sleep, idle or user switch,
/// which also clears the copy boost; nothing here is ever written to disk.
public struct SearchIndex: Sendable {
    /// At most this many rows are rendered (spec 5.1).
    public static let maxResults = 50

    private struct Record: Sendable {
        let entry: VaultEntry
        let folderName: String?
        let organizationName: String?
        let name: SearchText
        let nameWordStarts: [Int]
        let username: SearchText
        let hosts: [(text: SearchText, labelStarts: [Int])]

        func tier(for query: SearchText) -> MatchTier? {
            if name == query { return .exact }
            if name.hasPrefix(query) { return .namePrefix }
            if nameWordStarts.contains(where: { name.hasPrefix(query, at: $0) }) { return .wordPrefix }
            if hosts.contains(where: { host in host.labelStarts.contains { host.text.hasPrefix(query, at: $0) } }) {
                return .host
            }
            if name.containsSubsequence(query) || username.containsSubsequence(query)
                || hosts.contains(where: { $0.text.containsSubsequence(query) })
            {
                return .fuzzy
            }
            return nil
        }
    }

    /// A matching record's sort key: tier, then copy recency (`Int.max` when not copied), then position.
    private struct Match: Comparable {
        let tier: MatchTier
        let boost: Int
        let position: Int

        static func < (lhs: Match, rhs: Match) -> Bool {
            if lhs.tier != rhs.tier { return lhs.tier.rawValue < rhs.tier.rawValue }
            if lhs.boost != rhs.boost { return lhs.boost < rhs.boost }
            return lhs.position < rhs.position
        }
    }

    /// Sorted by folded name, then id, so a record's position is its tie-break inside a tier.
    private var records: [Record] = []
    private var positions: [String: Int] = [:]
    /// Ids copied this session, newest first. In memory only (spec 5.1).
    private var recentCopies: [String] = []

    public init(
        entries: [VaultEntry] = [], folders: [VaultFolder] = [], organizations: [VaultOrganization] = []
    ) {
        replaceEntries(entries, folders: folders, organizations: organizations)
    }

    /// Rebuilds the index after a sync (spec 2.1), keeping the copy boost for items that are still there.
    public mutating func replaceEntries(
        _ entries: [VaultEntry], folders: [VaultFolder] = [], organizations: [VaultOrganization] = []
    ) {
        let folderNames = Dictionary(
            folders.compactMap { folder in folder.id.map { ($0, folder.name) } },
            uniquingKeysWith: { first, _ in first })
        let organizationNames = Dictionary(
            organizations.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        records = entries.map { entry in
            let name = SearchText(entry.name)
            return Record(
                entry: entry,
                folderName: entry.folderId.flatMap { folderNames[$0] },
                organizationName: entry.organizationId.flatMap { organizationNames[$0] },
                name: name,
                nameWordStarts: name.innerWordStarts,
                username: SearchText(entry.username ?? ""),
                hosts: entry.hosts.map { host in
                    let text = SearchText(host)
                    return (text, text.labelStarts)
                })
        }
        .sorted { $0.name == $1.name ? $0.entry.id < $1.entry.id : $0.name.precedes($1.name) }
        positions = Dictionary(
            records.enumerated().map { ($1.entry.id, $0) }, uniquingKeysWith: { first, _ in first })
        recentCopies.removeAll { positions[$0] == nil }
    }

    /// Records a copy of the item, for the ranking boost and the empty-query list.
    public mutating func recordCopy(id: String) {
        guard positions[id] != nil else { return }
        recentCopies.removeAll { $0 == id }
        recentCopies.insert(id, at: 0)
    }

    /// Ranked results for `query`, at most `maxResults`.
    ///
    /// Tiers come first; inside a tier, items copied this session come first (most recent first), then name
    /// order. An empty query lists this session's copies, newest first, or favorites when nothing was copied.
    public func search(_ query: String) -> [SearchResult] {
        let query = SearchText(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return emptyQueryResults() }

        let boost = Dictionary(uniqueKeysWithValues: recentCopies.enumerated().map { ($1, $0) })
        let matches = records.indices.compactMap { position -> Match? in
            guard let tier = records[position].tier(for: query) else { return nil }
            return Match(tier: tier, boost: boost[records[position].entry.id] ?? Int.max, position: position)
        }
        return matches.sorted()
            .prefix(Self.maxResults)
            .map { result(records[$0.position], tier: $0.tier) }
    }

    private func emptyQueryResults() -> [SearchResult] {
        let list =
            recentCopies.isEmpty
            ? records.filter(\.entry.favorite) : recentCopies.compactMap { positions[$0].map { records[$0] } }
        return list.prefix(Self.maxResults).map { result($0, tier: nil) }
    }

    private func result(_ record: Record, tier: MatchTier?) -> SearchResult {
        SearchResult(
            entry: record.entry, folderName: record.folderName, organizationName: record.organizationName, tier: tier)
    }
}
