import Foundation

/// Background work (spec 7.3): after unlock the folder and organization names, then one `bw sync`, then one sync per
/// interval while unlocked. The interval comes from Settings; Off keeps only the sync after unlock.
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
            if syncingFirst {
                await self?.loadDetails()
                await self?.backgroundSync()
            }
            guard let interval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.backgroundSync()
            }
        }
    }

    /// Folder and organization names, and the account when this run hasn't seen `bw status` yet, after search opened
    /// on the items alone. Runs first in the background loop, before the sync after unlock. A lock meanwhile makes
    /// the calls throw, and nothing is applied.
    func loadDetails() async {
        guard isUnlocked else { return }
        let generation = generation
        updateSyncStatus { $0.activity = .loadingDetails }
        do {
            let names = try await listNamesWithSession()
            index?.setNames(folders: names.folders, organizations: names.organizations)
            if account.email == nil {
                let status = try await statusWithSession()
                account.remember(status)
                if syncState.lastSyncedAt == nil { updateSyncStatus { $0.lastSyncedAt = status.lastSync } }
            }
        } catch {
            Self.logger.error("Loading folders failed: \(diagnosticKind(of: error), privacy: .public)")
        }
        guard generation == self.generation else { return }
        updateSyncStatus { if $0.activity == .loadingDetails { $0.activity = nil } }
    }

    func updateSyncStatus(_ change: (inout SyncStatus) -> Void) {
        let previous = syncState
        change(&syncState)
        if syncState != previous { syncStatusContinuation.yield(syncState) }
    }

    /// `rebuild(afterSyncWith:)`, then the outcome in the sync status, unless the session was cleared meanwhile.
    func syncAndPublish(with session: SessionKey, generation: Int) async throws {
        let result: Result<Void, any Error>
        do {
            try await rebuild(afterSyncWith: session, generation: generation)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        guard generation == self.generation else { throw BWError.locked }
        runningSync = nil
        let now = clock.now()
        updateSyncStatus { status in
            status.activity = nil
            switch result {
            case .success:
                status.lastSyncedAt = now
                status.failure = nil
            case .failure(let error):
                status.failure = SyncFailure(error: error)
            }
        }
        try result.get()
    }

    func rebuild(afterSyncWith session: SessionKey, generation: Int) async throws {
        try await client.sync(session: session)
        // Cleared while `bw sync` ran: never list the decrypted vault for a session that is gone.
        guard generation == self.generation, !Task.isCancelled else { throw BWError.locked }
        updateSyncStatus { $0.activity = .refreshing }
        let rebuilt = try await client.listVault(session: session)
        guard generation == self.generation else { throw BWError.locked }
        index?.replaceEntries(rebuilt.entries, folders: rebuilt.folders, organizations: rebuilt.organizations)
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
