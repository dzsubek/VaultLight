import Foundation

/// The account as the panel, the menu and Settings show it, and the settings that apply at once.
extension SessionManager {
    /// What the panel, the menu and Settings show about the account (designs 06, 07, 13, 14). Starts no process.
    public func summary() -> VaultSummary {
        account.summary(isUnlocked: isUnlocked, loginCount: index?.count)
    }

    /// `bw status`, remembering the account for `summary()`.
    public func accountStatus() async throws -> BWStatus {
        let status = try await client.status()
        account.remember(status)
        return status
    }

    public func updateSettings(_ settings: SessionSettings) {
        policy.settings = settings
    }
}
