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
