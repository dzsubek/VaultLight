import Foundation

/// What the panel shows (spec 3.1). A missing or unsafe `bw` is reported by the `BWError` a call throws.
public enum VaultState: Sendable, Equatable {
    /// `bw` is logged out: onboarding (spec 3.2).
    case needsOnboarding
    /// Locked with no usable stored session: the master password field.
    case needsMasterPassword(MasterPasswordReason)
    /// Locked, and a stored session within its maximum age exists: "Touch ID to unlock".
    case storedSessionAvailable
    /// Search is ready.
    case unlocked
}

/// Why the master password is needed, for the footer (design Screen 7).
public enum MasterPasswordReason: Sendable, Equatable {
    case noStoredSession
    /// The stored session was created before the last restart (spec 3.5).
    case restarted
    /// The stored session passed its maximum age.
    case storedSessionExpired
    /// `bw` no longer accepted the stored session (spec 3.4 step 5).
    case sessionRejected
}

/// System notifications that clear the in-memory session (spec 3.5). The app maps NSWorkspace and distributed
/// notifications to these; tests yield them directly.
public enum SystemEvent: Sendable {
    case willSleep
    case screenLocked
    /// Fast user switching moved this login session to the background.
    case sessionResigned
}

/// A step of `SessionManager.unlock(masterPassword:progress:)`, for the onboarding checklist (design 12).
public enum UnlockProgress: Sendable, Equatable {
    case vaultUnlocked
    /// Whether the session key reached the Keychain; when it didn't, Touch ID won't be offered next time.
    case sessionSaved(Bool)
    case indexBuilt(logins: Int)
}

/// What is known about the account without starting a process (`SessionManager.summary()`).
public struct VaultSummary: Sendable, Equatable {
    public var isUnlocked: Bool
    public var email: String?
    public var serverURL: String?
    /// When the stored session reaches its maximum age; `nil` when there is none or its date isn't known yet.
    public var storedSessionExpiresAt: Date?
    /// Logins in the index while unlocked.
    public var loginCount: Int?

    public init(
        isUnlocked: Bool = false, email: String? = nil, serverURL: String? = nil,
        storedSessionExpiresAt: Date? = nil, loginCount: Int? = nil
    ) {
        self.isUnlocked = isUnlocked
        self.email = email
        self.serverURL = serverURL
        self.storedSessionExpiresAt = storedSessionExpiresAt
        self.loginCount = loginCount
    }
}
