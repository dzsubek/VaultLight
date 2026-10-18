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
            title = String(localized: "Unlocked", bundle: .module)
            let synced = lastSyncedAt.map {
                String(localized: "synced \(RelativeTime.ago(now.timeIntervalSince($0)))", bundle: .module)
            }
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
            title = String(localized: "Not signed in", bundle: .module)
            detail = String(localized: "Open VaultLight to set up", bundle: .module)
        case .storedSessionAvailable:
            title = String(localized: "Locked", bundle: .module)
            if let expiry = summary.storedSessionExpiresAt, expiry > now {
                detail = String(
                    localized:
                        "Touch ID unlocks · session expires in \(RelativeTime.duration(expiry.timeIntervalSince(now)))",
                    bundle: .module)
            } else {
                detail = String(localized: "Touch ID unlocks", bundle: .module)
            }
        case .needsMasterPassword(let reason):
            title = String(localized: "Locked", bundle: .module)
            detail = reason.footer
        case .unlocked, nil:
            title = String(localized: "Locked", bundle: .module)
            detail = nil
        }
    }
}
