import Foundation

/// Where the unlocked session key is kept between in-memory sessions (spec 3.3). Only `SessionManager` uses it.
public protocol SessionStore: Sendable {
    /// Whether a session is stored and, when it can be known without user presence, when it was created. Never
    /// prompts, so an expired session is caught before Touch ID (spec 3.3).
    func storedSession() async throws -> StoredSession

    /// The stored session key with its creation date, which is authoritative. Asks for user presence (Touch ID,
    /// Apple Watch or the login password); `reason` is the text the system sheet shows.
    func readSession(reason: String) async throws -> StoredSessionRead

    /// Replaces any stored session. Doesn't prompt.
    func saveSession(_ key: SessionKey, createdAt: Date) async throws

    /// Deletes the stored session. Succeeds when there is none.
    func deleteSession() async throws
}

/// What `SessionStore.storedSession()` can tell without user presence.
public enum StoredSession: Sendable, Equatable {
    /// No stored session.
    case none
    /// A session exists and was created at this date.
    case created(Date)
    /// A session exists, but its date can't be read without user presence. Offer Touch ID; the date read together
    /// with the key decides.
    case dateUnknown
}

/// The session key with its creation date, read together after user presence.
public struct StoredSessionRead: Sendable, Equatable {
    public let key: SessionKey
    public let createdAt: Date

    public init(key: SessionKey, createdAt: Date) {
        self.key = key
        self.createdAt = createdAt
    }
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
