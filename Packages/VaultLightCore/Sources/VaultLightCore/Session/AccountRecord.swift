import Foundation

/// What `SessionManager` knows about the account without starting a process: the last `bw status` and the stored
/// session's expiry. In memory only; replaced on sign-out.
struct AccountRecord {
    var email: String?
    var serverURL: String?
    /// When the stored session reaches its maximum age, once its creation date is known.
    var storedSessionExpiresAt: Date?
    /// The CLI's last successful sync, from `bw status`: where the footer's "Synced … ago" starts (spec 7.3).
    var lastSync: Date?

    mutating func remember(_ status: BWStatus) {
        if status.state == .unauthenticated {
            email = nil
            serverURL = status.serverURL
            lastSync = nil
            return
        }
        lastSync = status.lastSync ?? lastSync
        email = status.userEmail ?? email
        serverURL = status.serverURL ?? serverURL
    }

    func summary(isUnlocked: Bool, loginCount: Int?) -> VaultSummary {
        VaultSummary(
            isUnlocked: isUnlocked, email: email, serverURL: serverURL, storedSessionExpiresAt: storedSessionExpiresAt,
            loginCount: loginCount)
    }
}
