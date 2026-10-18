import Foundation

/// The menu-bar menu's status line and which commands work (spec 8, design 13): Sync Now and Lock Now only while
/// unlocked. Built from what is known without starting a process.
public struct MenuStatus: Sendable, Equatable {
    public let title: String
    public let detail: String?
    public let canSync: Bool
    public let canLock: Bool

    /// `state` is the last state the panel showed, `nil` before the first check. A session that is still unlocked
    /// wins over it.
    public init(state: VaultState?, summary: VaultSummary, lastSyncedAt: Date? = nil, now: Date) {
        if summary.isUnlocked {
            title = "Unlocked"
            let synced = lastSyncedAt.map { "synced \(RelativeTime.ago(now.timeIntervalSince($0)))" }
            let parts = [summary.email, synced].compactMap(\.self)
            detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
            canSync = true
            canLock = true
            return
        }
        canSync = false
        canLock = false
        switch state {
        case .needsOnboarding:
            title = "Not signed in"
            detail = "Open VaultLight to set up"
        case .storedSessionAvailable:
            title = "Locked"
            if let expiry = summary.storedSessionExpiresAt, expiry > now {
                detail = "Touch ID unlocks · session expires in \(RelativeTime.duration(expiry.timeIntervalSince(now)))"
            } else {
                detail = "Touch ID unlocks"
            }
        case .needsMasterPassword(let reason):
            title = "Locked"
            detail = reason.footer
        case .unlocked, nil:
            title = "Locked"
            detail = nil
        }
    }
}
