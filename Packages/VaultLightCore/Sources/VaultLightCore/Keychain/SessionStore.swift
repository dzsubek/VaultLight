import Foundation

/// Where the unlocked session key is kept between in-memory sessions (spec 3.3). Only `SessionManager` uses it.
public protocol SessionStore: Sendable {
    /// When the stored session was created, or `nil` when there is none. Reads only a non-secret attribute and
    /// never prompts, so the maximum age is checked without Touch ID (spec 3.3).
    func storedSessionDate() async throws -> Date?

    /// The stored session key. Asks for user presence (Touch ID, Apple Watch or the login password); `reason` is
    /// the text the system sheet shows.
    func readSession(reason: String) async throws -> SessionKey

    /// Replaces any stored session. Doesn't prompt.
    func saveSession(_ key: SessionKey, createdAt: Date) async throws

    /// Deletes the stored session. Succeeds when there is none.
    func deleteSession() async throws
}

public enum SessionStoreError: Error, Equatable, Sendable {
    /// No stored session.
    case notFound
    /// The user dismissed the Touch ID or password sheet.
    case cancelled
    /// User presence could not be confirmed.
    case authenticationFailed
    /// Any other Keychain or LocalAuthentication failure, with its `OSStatus`.
    case unavailable(Int32)
}
