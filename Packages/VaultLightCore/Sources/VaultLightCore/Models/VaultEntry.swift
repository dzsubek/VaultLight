import Foundation

/// The searchable metadata of one login item (spec 9.1 "Metadata-only index").
///
/// It deliberately has no password, TOTP seed, notes or custom-field properties.
/// It is not `Encodable`, so it can't be written to disk by accident.
public struct VaultEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let username: String?
    /// The login's URIs, in vault order. The first is the primary URI (⌘O).
    public let uris: [String]
    /// The host of each URI that has one, lowercased, in the same order.
    public let hosts: [String]
    public let folderId: String?
    public let organizationId: String?
    public let favorite: Bool
    public let hasTOTP: Bool

    public init(
        id: String, name: String, username: String? = nil, uris: [String] = [], folderId: String? = nil,
        organizationId: String? = nil, favorite: Bool = false, hasTOTP: Bool = false
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.uris = uris.compactMap(Self.withoutCredentials)
        self.hosts = self.uris.compactMap(Self.host(of:))
        self.folderId = folderId
        self.organizationId = organizationId
        self.favorite = favorite
        self.hasTOTP = hasTOTP
    }

    /// The host shown on the result row (spec 5.2).
    public var primaryHost: String? { hosts.first }

    /// The URI without a user name or password (`postgres://app:pw@db` → `postgres://db`), so a password
    /// written into a URI never stays in the index (spec 9.1). A URI with "@" that can't be parsed is dropped.
    static func withoutCredentials(_ uri: String) -> String? {
        guard uri.contains("@") else { return uri }
        let hadScheme = hasScheme(uri)
        guard var components = URLComponents(string: withScheme(uri)) else { return nil }
        components.user = nil
        components.password = nil
        guard var text = components.string else { return nil }
        if !hadScheme { text.removeFirst(defaultScheme.count) }
        return text
    }

    /// The lowercased host of a URI.
    static func host(of uri: String) -> String? {
        let components = URLComponents(string: withScheme(uri.trimmingCharacters(in: .whitespaces)))
        guard let host = components?.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    /// Bitwarden allows URIs without a scheme ("example.com"), so those are read as https.
    private static let defaultScheme = "https://"

    private static func withScheme(_ uri: String) -> String {
        hasScheme(uri) ? uri : defaultScheme + uri
    }

    /// A scheme counts only at the start (RFC 3986), not a "://" later in a query.
    private static func hasScheme(_ uri: String) -> Bool {
        uri.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*://"#, options: .regularExpression) != nil
    }
}

/// Only the id, so a stray interpolation can't put an item name, username or URI into a log or error text.
extension VaultEntry: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "VaultEntry(id: \(id))" }
    public var debugDescription: String { description }
}

extension VaultEntry {
    /// One element of `bw list items`, for `BWClient.listItems`.
    ///
    /// Only the metadata keys are decoded; passwords, notes, custom fields and every other key are never
    /// read into a property. `entry` is `nil` for any item that isn't a login (spec 5.1: v1 searches logins
    /// only).
    public struct Listed: Decodable, Sendable {
        public let entry: VaultEntry?

        private static let loginType = 1

        public init(from decoder: any Decoder) throws {
            let item = try decoder.container(keyedBy: ItemKeys.self)
            guard try item.decode(Int.self, forKey: .type) == Self.loginType else {
                entry = nil
                return
            }
            let login = try? item.nestedContainer(keyedBy: LoginKeys.self, forKey: .login)
            // The TOTP seed is only checked for presence; the string is dropped at once.
            let totp = try login?.decodeIfPresent(String.self, forKey: .totp)
            entry = VaultEntry(
                id: try item.decode(String.self, forKey: .id),
                name: try item.decode(String.self, forKey: .name),
                username: try login?.decodeIfPresent(String.self, forKey: .username),
                uris: try login?.decodeIfPresent([ListedURI].self, forKey: .uris)?.compactMap(\.uri) ?? [],
                folderId: try item.decodeIfPresent(String.self, forKey: .folderId),
                organizationId: try item.decodeIfPresent(String.self, forKey: .organizationId),
                favorite: try item.decodeIfPresent(Bool.self, forKey: .favorite) ?? false,
                hasTOTP: !(totp ?? "").isEmpty)
        }
    }
}

private enum ItemKeys: String, CodingKey {
    case id, type, name, folderId, organizationId, favorite, login
}

private enum LoginKeys: String, CodingKey {
    case username, uris, totp
}

private struct ListedURI: Decodable {
    let uri: String?
}
