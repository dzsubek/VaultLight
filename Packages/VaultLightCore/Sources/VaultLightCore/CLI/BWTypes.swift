import Foundation

/// A Bitwarden session key. Its description never contains the value, so it can't leak through
/// string interpolation, `dump` or a debugger summary.
public struct SessionKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { "SessionKey(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// `bw status` output (spec 3.1).
public struct BWStatus: Sendable, Equatable, Decodable {
    public enum State: String, Sendable, Decodable {
        case unauthenticated, locked, unlocked
    }

    public let state: State
    public let serverURL: String?
    public let userEmail: String?
    /// The CLI's last successful sync; `nil` before the first one or when the value can't be read.
    public let lastSync: Date?

    enum CodingKeys: String, CodingKey {
        case state = "status"
        case serverURL = "serverUrl"
        case userEmail
        case lastSync
    }

    public init(state: State, serverURL: String?, userEmail: String?, lastSync: Date? = nil) {
        self.state = state
        self.serverURL = serverURL
        self.userEmail = userEmail
        self.lastSync = lastSync
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(State.self, forKey: .state)
        serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL)
        userEmail = try container.decodeIfPresent(String.self, forKey: .userEmail)
        // Only the footer uses it, so an unexpected value never fails the status check.
        let text = try? container.decodeIfPresent(String.self, forKey: .lastSync)
        lastSync = text.flatMap(Self.parseDate)
    }

    /// ISO 8601 as `bw` writes it ("2026-10-17T08:00:00.123Z"), with or without fractional seconds.
    private static func parseDate(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}

/// A dotted `bw` version such as `2026.9.0`.
public struct BWVersion: Sendable, Comparable, CustomStringConvertible {
    public let components: [Int]

    public init(components: [Int]) { self.components = components }

    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(
            separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !parts.isEmpty, numbers.count == parts.count else { return nil }
        components = numbers
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    /// Missing trailing components count as zero, so 2025.1 == 2025.1.0.
    private func padded(to count: Int) -> [Int] { components + Array(repeating: 0, count: count - components.count) }

    public static func == (lhs: BWVersion, rhs: BWVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count) == rhs.padded(to: count)
    }

    public static func < (lhs: BWVersion, rhs: BWVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count).lexicographicallyPrecedes(rhs.padded(to: count))
    }
}

/// A two-step login code for `bw login --method <m> --code <c>` (spec 7.2). The code is one-time, so it may be an argument.
public struct BWTwoFactor: Sendable {
    public enum Method: Int, Sendable {
        case authenticator = 0
        case email = 1
    }

    /// With a code, `--method` makes `bw` send the code in its first request. Without `--method`, `bw` first asks
    /// without a code, and the server's "two-step required" answer replaces the emailed code, so it stops working.
    public let method: Method
    /// `nil` asks `bw` to start the method without a code: for email, the server sends one ("Send a code by
    /// email", design 11).
    public let code: String?

    public init(method: Method, code: String?) {
        self.method = method
        self.code = code
    }
}
