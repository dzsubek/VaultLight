import Foundation
import Testing

@testable import VaultLightCore

/// Design 08: the footer's sync line when nothing more urgent is shown.
@Suite("Sync footer")
struct SyncFooterTests {
    let now = Date(timeIntervalSince1970: 1_792_224_000)

    func status(syncedAgo seconds: TimeInterval?, failure: SyncFailure? = nil, syncing: Bool = false) -> SyncStatus {
        SyncStatus(lastSyncedAt: seconds.map { now.addingTimeInterval(-$0) }, failure: failure, isSyncing: syncing)
    }

    @Test func syncedShowsTheTimeSinceTheLastSync() {
        #expect(
            status(syncedAgo: 180).footerLine(now: now)
                == SyncLine(tone: .neutral, text: "Synced 3 min ago", offersRetry: false))
        #expect(status(syncedAgo: 20).footerLine(now: now)?.text == "Synced just now")
        #expect(status(syncedAgo: 2 * 3_600).footerLine(now: now)?.text == "Synced 2 h ago")
    }

    @Test func offlineShowsTheCachedVaultWarning() {
        let expected = SyncLine(tone: .warning, text: "Offline — showing cached vault", offersRetry: false)
        #expect(status(syncedAgo: 180, failure: .offline).footerLine(now: now) == expected)
        #expect(status(syncedAgo: nil, failure: .offline).footerLine(now: now) == expected)
    }

    @Test func otherFailuresOfferTryAgain() {
        #expect(
            status(syncedAgo: 3_600, failure: .failed).footerLine(now: now)
                == SyncLine(tone: .error, text: "Sync failed — last synced 1 h ago", offersRetry: true))
        #expect(
            status(syncedAgo: nil, failure: .failed).footerLine(now: now)
                == SyncLine(tone: .error, text: "Sync failed", offersRetry: true))
    }

    @Test func aRunningSyncKeepsTheLastLine() {
        #expect(status(syncedAgo: 180, syncing: true).footerLine(now: now)?.text == "Synced 3 min ago")
        #expect(status(syncedAgo: 180, failure: .failed, syncing: true).footerLine(now: now)?.tone == .error)
    }

    @Test func theFirstSyncShowsSyncing() {
        #expect(
            status(syncedAgo: nil, syncing: true).footerLine(now: now)
                == SyncLine(tone: .neutral, text: "Syncing…", offersRetry: false))
        #expect(SyncStatus().footerLine(now: now) == nil)
    }

    /// A clock that jumped back never shows a negative age.
    @Test func aFutureSyncTimeReadsAsJustNow() {
        #expect(status(syncedAgo: -600).footerLine(now: now)?.text == "Synced just now")
    }
}
