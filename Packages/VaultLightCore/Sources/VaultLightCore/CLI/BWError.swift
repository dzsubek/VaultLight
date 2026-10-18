import Foundation

/// Typed failures of `bw` calls (spec 7.4). The UI picks its message from the case, never from raw output.
public enum BWError: Error, Equatable, Sendable {
    /// No executable `bw` at the configured or pinned paths.
    case notInstalled
    /// `bw` is owned by someone other than the user or root, or writable by group or others (spec 7.1).
    case unsafeBinary
    /// Installed version is below `BWClient.minimumVersion`.
    case tooOld(installed: String)
    /// `bw status` would report `unauthenticated`: log in first.
    case unauthenticated
    /// The vault is locked or the session key was rejected.
    case locked
    /// Wrong master password, on unlock or email login. Doesn't say whether the email was the wrong part.
    case invalidPassword
    /// Wrong `client_id` or `client_secret`.
    case invalidAPIKey
    /// The account needs a two-step login code.
    case twoFactorRequired
    /// The two-step login code was wrong.
    case invalidTwoFactorCode
    /// The server could not be reached.
    case network
    /// The call ran past its timeout and was killed.
    case timeout
    /// No item with that id.
    case itemNotFound
    /// The item has no password or TOTP to copy.
    case noValue
    /// An argument failed validation before any process started (e.g. an email starting with `-`).
    case invalidArgument
    /// Anything else. The text is the first line of stderr, with the call's secrets and email addresses masked.
    case unknown(String)
}

extension BWError {
    /// Maps a failed call's stderr to a typed error. `secrets` are the values the call passed in its environment.
    static func classify(stderr: String, exitStatus: Int32, secrets: [String]) -> BWError {
        let lines = messageLines(of: stderr)
        let message = lines.first ?? ""
        // Known messages are looked for in every line: `bw` can print warnings or SDK tracing lines first.
        let text = lines.joined(separator: "\n").lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }

        if has("you are not logged in") { return .unauthenticated }
        if has("vault is locked") { return .locked }
        // `bw` 2025.x unlocks through the Bitwarden SDK, which reports a wrong master password as a failed decryption.
        if has("invalid master password", "username or password is incorrect", "the decryption operation failed") {
            return .invalidPassword
        }
        if has("client_id or client_secret is incorrect") { return .invalidAPIKey }
        if has("two-step token is invalid") { return .invalidTwoFactorCode }
        if has("two-step login code is required", "code is required") { return .twoFactorRequired }
        if has(
            "fetcherror", "enotfound", "econnrefused", "econnreset", "etimedout", "eai_again", "getaddrinfo",
            "socket hang up", "network error", "failed to fetch")
        {
            return .network
        }
        if text == "not found." { return .itemNotFound }
        if has("no password available", "no totp available") { return .noValue }
        if message.isEmpty { return .unknown("bw exited with status \(exitStatus)") }
        return .unknown(redact(message, secrets: secrets))
    }

    private static let maximumMessageLength = 200

    /// Non-empty lines without ANSI colour codes, minus the SDK's Rust tracing lines
    /// (`ERROR bitwarden_core::client::internal: …`), so the first one is `bw`'s own message.
    private static func messageLines(of output: String) -> [String] {
        let plain = output.replacing(/\u{1B}\[[0-9;]*m/, with: "")
        let lines = plain.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let messages = lines.filter { $0.firstMatch(of: /^(ERROR|WARN|INFO|DEBUG|TRACE) [A-Za-z0-9_]+::/) == nil }
        return messages.isEmpty ? lines : messages
    }

    private static func redact(_ message: String, secrets: [String]) -> String {
        var redacted = message
        for secret in secrets where !secret.isEmpty {
            redacted = redacted.replacingOccurrences(of: secret, with: "[redacted]")
        }
        redacted = redacted.replacing(/[^\s@"'<>()]+@[^\s@"'<>()]+/, with: "[email]")
        return String(redacted.prefix(maximumMessageLength))
    }
}

extension BWError {
    /// The case name alone, never its payload, so logs can show it in clear text (`privacy: .public`) and a
    /// failure can be diagnosed without exposing redacted `bw` output.
    public var diagnosticKind: String {
        switch self {
        case .notInstalled: "notInstalled"
        case .unsafeBinary: "unsafeBinary"
        case .tooOld: "tooOld"
        case .unauthenticated: "unauthenticated"
        case .locked: "locked"
        case .invalidPassword: "invalidPassword"
        case .invalidAPIKey: "invalidAPIKey"
        case .twoFactorRequired: "twoFactorRequired"
        case .invalidTwoFactorCode: "invalidTwoFactorCode"
        case .network: "network"
        case .timeout: "timeout"
        case .itemNotFound: "itemNotFound"
        case .noValue: "noValue"
        case .invalidArgument: "invalidArgument"
        case .unknown: "unknown"
        }
    }
}

/// A clear-text label for any error: a `BWError`'s or `SessionStoreError`'s case name (with the Keychain
/// `OSStatus`, a public error code), otherwise the error's type name. Never a message or payload.
public func diagnosticKind(of error: any Error) -> String {
    switch error {
    case let error as BWError: error.diagnosticKind
    case SessionStoreError.notFound: "SessionStoreError.notFound"
    case SessionStoreError.cancelled: "SessionStoreError.cancelled"
    case SessionStoreError.authenticationFailed: "SessionStoreError.authenticationFailed"
    case SessionStoreError.unavailable(let status): "SessionStoreError.unavailable(\(status))"
    default: String(describing: type(of: error))
    }
}
