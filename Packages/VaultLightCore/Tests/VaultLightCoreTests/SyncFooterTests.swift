import Foundation
import Testing

@testable import VaultLightCore

/// Design 08: the footer's sync line when nothing more urgent is shown.
@Suite("Sync footer")
struct SyncFooterTests {
    let now = Date(timeIntervalSince1970: 1_792_224_000)

    func status(
        syncedAgo seconds: TimeInterval?, failure: SyncFailure? = nil, activity: SyncActivity? = nil
    ) -> SyncStatus {
        SyncStatus(lastSyncedAt: seconds.map { now.addingTimeInterval(-$0) }, failure: failure, activity: activity)
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

    /// Background work shows a spinner and what runs, over the last result (the `bw` calls take seconds each).
    @Test func backgroundWorkShowsWhatRuns() {
        #expect(
            status(syncedAgo: 180, activity: .syncing).footerLine(now: now)
                == SyncLine(tone: .busy, text: "Syncing…", offersRetry: false))
        #expect(status(syncedAgo: nil, activity: .loadingDetails).footerLine(now: now)?.text == "Loading folders…")
        #expect(status(syncedAgo: 180, activity: .refreshing).footerLine(now: now)?.text == "Updating search…")
        #expect(status(syncedAgo: 180, failure: .failed, activity: .syncing).footerLine(now: now)?.tone == .busy)
        #expect(SyncStatus().footerLine(now: now) == nil)
    }

    @Test func onlyASyncAndItsRebuildCountAsSyncing() {
        #expect(SyncStatus(activity: .syncing).isSyncing)
        #expect(SyncStatus(activity: .refreshing).isSyncing)
        #expect(!SyncStatus(activity: .loadingDetails).isSyncing)
    }

    /// A clock that jumped back never shows a negative age.
    @Test func aFutureSyncTimeReadsAsJustNow() {
        #expect(status(syncedAgo: -600).footerLine(now: now)?.text == "Synced just now")
    }
}
