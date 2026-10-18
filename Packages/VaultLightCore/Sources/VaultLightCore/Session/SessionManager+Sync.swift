import Foundation

/// Background sync (spec 7.3): one `bw sync` right after unlock, then one per interval while unlocked. The interval
/// comes from Settings; Off keeps only the sync after unlock.
extension SessionManager {
    /// The sync status now; `syncStatusUpdates` carries every change.
    public func syncStatus() -> SyncStatus {
        syncState
    }

    /// Reschedules background sync with the new interval while unlocked. The next sync is one interval away.
    public func setBackgroundSyncInterval(_ interval: Duration?) {
        backgroundSyncInterval = interval
        if isUnlocked { startBackgroundSync(syncingFirst: false) }
    }

    func startBackgroundSync(syncingFirst: Bool) {
        syncTask?.cancel()
        syncTask = nil
        let interval = backgroundSyncInterval
        guard isUnlocked, syncingFirst || interval != nil else { return }
        syncTask = Task { [weak self] in
            if syncingFirst { await self?.backgroundSync() }
            guard let interval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.backgroundSync()
            }
        }
    }

    func updateSyncStatus(_ change: (inout SyncStatus) -> Void) {
        let previous = syncState
        change(&syncState)
        if syncState != previous { syncStatusContinuation.yield(syncState) }
    }

    /// Failures reach the footer through the status; here they are only logged, without values.
    private func backgroundSync() async {
        do {
            try await sync()
        } catch {
            Self.logger.error("Background sync failed: \(diagnosticKind(of: error), privacy: .public)")
        }
    }
}
