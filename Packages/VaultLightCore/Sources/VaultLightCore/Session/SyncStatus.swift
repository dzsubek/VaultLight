import Foundation

/// Background sync as the footer, the menu and Settings show it (spec 7.3, design 08). `SessionManager` owns it and
/// clears it with the session. Holds no vault content.
public struct SyncStatus: Sendable, Equatable {
    /// The last successful `bw sync`, starting from the time `bw status` reports; `nil` when unknown.
    public var lastSyncedAt: Date?
    /// Why the last sync failed; `nil` once one succeeds.
    public var failure: SyncFailure?
    /// The background work running now; the footer shows it with a spinner.
    public var activity: SyncActivity?

    /// A `bw sync` or the index rebuild after it is running; Sync Now joins it.
    public var isSyncing: Bool { activity == .syncing || activity == .refreshing }

    public init(lastSyncedAt: Date? = nil, failure: SyncFailure? = nil, activity: SyncActivity? = nil) {
        self.lastSyncedAt = lastSyncedAt
        self.failure = failure
        self.activity = activity
    }
}

/// Background work after unlock and on each sync. Every step is a `bw` call of a few seconds, so
/// the footer says which one runs.
public enum SyncActivity: Sendable, Equatable {
    /// Folder and organization names (and the account, when not known yet) after search opened on the items alone.
    case loadingDetails
    /// `bw sync`.
    case syncing
    /// The index rebuilt from `bw list` after a sync.
    case refreshing

    public var message: String {
        switch self {
        case .loadingDetails: String(localized: "Loading folders…", bundle: .module)
        case .syncing: String(localized: "Syncing…", bundle: .module)
        case .refreshing: String(localized: "Updating search…", bundle: .module)
        }
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
        /// A spinner: background work is running.
        case busy
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
    /// What the footer shows while no copy confirmation or error is (design 08); `nil` before anything is known.
    /// Running work comes first, with a spinner: each step takes seconds.
    public func footerLine(now: Date) -> SyncLine? {
        if let activity { return SyncLine(tone: .busy, text: activity.message, offersRetry: false) }
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
            return nil
        }
    }
}
