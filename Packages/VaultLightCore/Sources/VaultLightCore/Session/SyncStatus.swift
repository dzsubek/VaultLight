import Foundation

/// Background sync as the footer, the menu and Settings show it (spec 7.3, design 08). `SessionManager` owns it and
/// clears it with the session. Holds no vault content.
public struct SyncStatus: Sendable, Equatable {
    /// The last successful `bw sync`, starting from the time `bw status` reports; `nil` when unknown.
    public var lastSyncedAt: Date?
    /// Why the last sync failed; `nil` once one succeeds.
    public var failure: SyncFailure?
    public var isSyncing: Bool

    public init(lastSyncedAt: Date? = nil, failure: SyncFailure? = nil, isSyncing: Bool = false) {
        self.lastSyncedAt = lastSyncedAt
        self.failure = failure
        self.isSyncing = isSyncing
    }
}

/// Why a sync failed (spec 7.4): offline keeps search on the cached vault and retries on the interval; anything
/// else (a timeout, a CLI error) offers "Try again".
public enum SyncFailure: Sendable, Equatable {
    case offline
    case failed

    public init(error: any Error) {
        self = (error as? BWError) == .network ? .offline : .failed
    }
}

/// One footer line about sync (design 08).
public struct SyncLine: Sendable, Equatable {
    public enum Tone: Sendable {
        /// Gray dot.
        case neutral
        /// Amber dot: offline, search keeps working on the cached vault.
        case warning
        /// Red dot, with "Try again".
        case error
    }

    public let tone: Tone
    public let text: String
    /// "Try again" is offered (design 08 "Sync error").
    public let offersRetry: Bool

    public init(tone: Tone, text: String, offersRetry: Bool) {
        self.tone = tone
        self.text = text
        self.offersRetry = offersRetry
    }
}

extension SyncStatus {
    /// What the footer shows while no copy confirmation or error is (design 08); `nil` before anything is known. A
    /// running sync keeps the previous line, so the footer doesn't flicker every interval.
    public func footerLine(now: Date) -> SyncLine? {
        let ago = lastSyncedAt.map { RelativeTime.ago(now.timeIntervalSince($0)) }
        switch failure {
        case .offline:
            return SyncLine(
                tone: .warning, text: String(localized: "Offline — showing cached vault", bundle: .module),
                offersRetry: false)
        case .failed:
            let text =
                ago.map { String(localized: "Sync failed — last synced \($0)", bundle: .module) }
                ?? String(localized: "Sync failed", bundle: .module)
            return SyncLine(tone: .error, text: text, offersRetry: true)
        case nil:
            if let ago {
                return SyncLine(
                    tone: .neutral, text: String(localized: "Synced \(ago)", bundle: .module), offersRetry: false)
            }
            return isSyncing
                ? SyncLine(tone: .neutral, text: String(localized: "Syncing…", bundle: .module), offersRetry: false)
                : nil
        }
    }
}
