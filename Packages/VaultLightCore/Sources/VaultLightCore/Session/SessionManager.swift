import Foundation
import os

/// Owns the unlocked session (spec 2, 3.4, 3.5): the session key, the search index built from it, and background
/// sync. Only this type reads the session store, and the session key never leaves it.
///
/// A watchdog checks the policy every `policyCheckInterval` while unlocked, so idle time and lifetimes end the
/// session even when nothing calls in: opening the panel is itself input and resets the idle time.
///
/// Every clear bumps `generation`. Work that awaits (an unlock, a sync, a copy) checks it before using its result,
/// so nothing finished after a lock can bring the session or index back.
public actor SessionManager {
    static let logger = Logger(subsystem: "com.vaultlight.core", category: "session")

    let client: BWClient
    let store: any SessionStore
    let clock: SessionClock
    private let policyCheckInterval: Duration
    var policy: SessionPolicy
    var backgroundSyncInterval: Duration?

    private var session: SessionKey?
    var index: SearchIndex?
    private var authenticatedAt: Date?
    /// Creation date of the stored session this one came from; its maximum age also ends the in-memory session.
    private var storedSessionCreatedAt: Date?
    private(set) var generation = 0
    var account = AccountRecord()
    /// The background loop: one sync after unlock, then one per interval.
    var syncTask: Task<Void, Never>?
    /// The `bw sync` running now; Sync Now joins it instead of queueing a second one.
    private var runningSync: Task<Void, any Error>?
    var syncState = SyncStatus()
    let syncStatusContinuation: AsyncStream<SyncStatus>.Continuation
    private var eventTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private let clearedContinuation: AsyncStream<Void>.Continuation

    /// Yields each time an unlocked session is cleared, for whatever reason, so the panel can close (spec 4.3).
    /// One listener only (the app's coordinator, which closes the panel and updates the menu): an `AsyncStream`
    /// hands each element to a single iterator.
    public nonisolated let sessionCleared: AsyncStream<Void>

    /// Yields the sync status each time it changes (spec 7.3, design 08), for one listener, as `sessionCleared`.
    public nonisolated let syncStatusUpdates: AsyncStream<SyncStatus>

    /// `backgroundSyncInterval` is how often `bw sync` runs while unlocked; `nil` turns background sync off.
    /// `policyCheckInterval` bounds how late the idle lock and the lifetimes can fire.
    public init(
        client: BWClient, store: any SessionStore, settings: SessionSettings = SessionSettings(),
        clock: SessionClock = .system, backgroundSyncInterval: Duration? = nil,
        policyCheckInterval: Duration = .seconds(15)
    ) {
        self.client = client
        self.store = store
        self.clock = clock
        self.policy = SessionPolicy(settings: settings)
        self.backgroundSyncInterval = backgroundSyncInterval
        self.policyCheckInterval = policyCheckInterval
        (sessionCleared, clearedContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (syncStatusUpdates, syncStatusContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        syncTask?.cancel()
        eventTask?.cancel()
        watchdogTask?.cancel()
        clearedContinuation.finish()
        syncStatusContinuation.finish()
    }

    public var isUnlocked: Bool { session != nil }

    /// Clears the in-memory session on every event of `events` (sleep, screen lock, fast user switch).
    public func observe(_ events: AsyncStream<SystemEvent>) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.clear(because: "\(event)")
            }
        }
    }

    // MARK: State and unlock (spec 3.4)

    /// The state to show when the panel opens. Starts no process when the in-memory session is valid or a stored
    /// session can be offered; deletes a stored session past its limits and runs `bw lock` (spec 3.5).
    public func refreshState() async throws -> VaultState {
        if enforcePolicy() { return .unlocked }
        // A missing or unsafe `bw` is reported before any Touch ID sheet (spec 3.1); this starts no process.
        _ = try await client.executable()
        return try await lockedState(storedSession: storedSessionVerdict())
    }

    /// `bw unlock` with the master password, then stores the session key (spec 3.2 steps 3–4). The password lives
    /// only for this call.
    ///
    /// `progress` reports each step for the onboarding checklist (design 12): the vault unlocked, whether the
    /// session reached the Keychain, then the index with its login count.
    public func unlock(
        masterPassword: String, progress: @Sendable (UnlockProgress) -> Void = { _ in }
    ) async throws -> VaultState {
        let generation = generation
        let key = try await client.unlock(password: masterPassword)
        progress(.vaultUnlocked)
        // Items only: search opens now, folder and organization names follow in the background.
        let entries = try await client.listEntries(session: key)
        guard generation == self.generation else { return try await refreshState() }
        let createdAt = clock.now()
        var saved = true
        do {
            try await store.saveSession(key, createdAt: createdAt)
        } catch {
            saved = false
            Self.logger.error("Storing the session failed: \(diagnosticKind(of: error), privacy: .public)")
        }
        progress(.sessionSaved(saved))
        guard generation == self.generation else {
            // A lock or "Lock and forget" ran while the key was being stored.
            do {
                try await store.deleteSession()
            } catch {
                Self.logger.error("Deleting the session failed: \(String(describing: error), privacy: .private)")
            }
            return try await refreshState()
        }
        install(key, entries: entries, storedSessionCreatedAt: createdAt)
        account.storedSessionExpiresAt =
            saved ? createdAt.addingTimeInterval(policy.settings.storedMaximumAge.seconds) : nil
        progress(.indexBuilt(logins: index?.count ?? 0))
        return .unlocked
    }

    /// Before the prompt only a date known without user presence ends the session; the date read with the key is
    /// authoritative. Reads the stored session behind Touch ID and confirms `bw` still accepts it (spec 3.4 steps 3–5).
    /// Throws `SessionStoreError.cancelled` when the user dismisses the sheet; the stored session is kept.
    /// `keyRead` runs once the sheet succeeded and the key is about to be tried, so the panel can say the vault is
    /// opening while `bw list items` runs.
    public func unlockWithStoredSession(
        reason: String, keyRead: @Sendable () -> Void = {}
    ) async throws -> VaultState {
        let generation = generation
        let precheck = try await storedSessionVerdict()
        guard precheck == .valid else { return try await lockedState(storedSession: precheck) }
        let read: StoredSessionRead
        do {
            read = try await store.readSession(reason: reason)
        } catch SessionStoreError.notFound {
            return try await refreshState()
        }
        // The sheet suspended this call: a clear, or a newer unlock, may have happened meanwhile.
        guard !isSuperseded(since: generation) else { return try await refreshState() }
        let verdict = try await storedSessionVerdict(createdAt: read.createdAt)
        guard verdict == .valid else { return try await lockedState(storedSession: verdict) }
        let key = read.key
        keyRead()
        try await client.checkVersion()
        // A successful `bw list items` confirms `bw` still accepts the session (spec 3.4 step 4); a separate
        // `bw status` would cost another few seconds.
        let entries: [VaultEntry]
        do {
            entries = try await client.listEntries(session: key)
        } catch {
            if let state = try await stateAfterFailedList(error, key: key, since: generation) { return state }
            throw error
        }
        guard !isSuperseded(since: generation) else { return try await refreshState() }
        install(key, entries: entries, storedSessionCreatedAt: read.createdAt)
        return .unlocked
    }

    // MARK: Clearing (spec 3.5)

    /// Clears the in-memory session if its lifetime, the idle limit or the stored session's maximum age has passed.
    /// Returns whether it is still unlocked. The watchdog, `refreshState`, search and every copy call this.
    @discardableResult
    public func enforcePolicy() -> Bool {
        guard session != nil, let authenticatedAt else { return false }
        let now = clock.now()
        var verdict = policy.inMemorySession(authenticatedAt: authenticatedAt, now: now, idleTime: clock.idleTime())
        if verdict == .valid, let storedSessionCreatedAt {
            // The restart rule can't apply inside the boot that unlocked; only the age counts here. The stored item
            // itself is deleted, and `bw` locked, by the next `refreshState`.
            verdict = policy.storedSession(createdAt: storedSessionCreatedAt, now: now, bootTime: .distantPast)
        }
        guard verdict == .valid else {
            clear(because: "\(verdict)")
            return false
        }
        return true
    }

    /// "Lock now": clears the in-memory session; the stored session stays for Touch ID.
    public func lockNow() {
        clear(because: "lock now")
    }

    /// "Lock and forget": clears the in-memory session, deletes the stored one, then runs `bw lock`.
    public func lockAndForget() async throws {
        account.storedSessionExpiresAt = nil
        try await clearAndForget { try await $0.lock() }
    }

    /// "Sign out" (spec 3.5): the local session goes first, so a failed `bw logout` leaves nothing usable. Clears
    /// the in-memory session and index, deletes the stored session, stops background sync, then runs `bw logout`.
    ///
    /// If `bw logout` fails, `bw lock` runs too, which invalidates every session key, including one whose Keychain
    /// delete failed. The error is still thrown: `bw` is then logged in, so onboarding can't start yet.
    public func signOut() async throws -> VaultState {
        account = AccountRecord()
        try await clearAndForget { client in
            do {
                try await client.logout()
            } catch {
                try? await client.lock()
                throw error
            }
        }
        return .needsOnboarding
    }

    // MARK: Using the session

    /// Ranked results; empty while locked. Starts no process.
    public func search(_ query: String) -> [SearchResult] {
        guard enforcePolicy() else { return [] }
        return index?.search(query) ?? []
    }

    /// Records a copy for the ranking boost (spec 5.1). Cleared with the index.
    public func recordCopy(id: String) {
        guard enforcePolicy() else { return }
        index?.recordCopy(id: id)
    }

    /// `bw get password`. Throws `BWError.locked` without starting a process when the session is gone or expired,
    /// and when it was cleared while `bw` ran.
    public func password(for id: String) async throws -> String {
        try await withSession { try await $0.getPassword(id: id, session: $1) }
    }

    /// `bw get totp`, with the same checks as `password(for:)`.
    public func totp(for id: String) async throws -> String {
        try await withSession { try await $0.getTOTP(id: id, session: $1) }
    }

    /// `bw sync`, then rebuilds the index, keeping the copy boost (spec 2.1, 7.3). Background sync and Sync Now both
    /// come here: a call while a sync runs joins it. The outcome goes to `syncStatusUpdates`, unless the session was
    /// cleared meanwhile.
    public func sync() async throws {
        if let runningSync { return try await runningSync.value }
        guard enforcePolicy(), let session else { throw BWError.locked }
        let generation = generation
        let running = Task { try await rebuild(afterSyncWith: session, generation: generation) }
        runningSync = running
        updateSyncStatus { $0.activity = .syncing }
        let result = await running.result
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
}

extension SessionManager {
    // MARK: Private

    /// Whether a clear ran since `generation` was read, or another unlock installed a session meanwhile.
    private func isSuperseded(since generation: Int) -> Bool {
        generation != self.generation || session != nil
    }

    /// Spec 3.4 step 5: whether a failed `bw list items` means the stored session no longer works. Other errors than
    /// "locked" and "not logged in" (bw 2025.x can report a wrong key as a decryption failure) are checked with `bw
    /// status`. Deletes the stored session and returns the state to show, or `nil` to let the error stand.
    private func stateAfterFailedList(
        _ error: any Error, key: SessionKey, since generation: Int
    ) async throws -> VaultState? {
        let state: BWStatus.State
        switch error as? BWError {
        case .locked: state = .locked
        case .unauthenticated: state = .unauthenticated
        case .timeout, .network, .notInstalled, .unsafeBinary, .tooOld: return nil
        default:
            guard !(error is CancellationError) else { return nil }
            state = try await client.status(session: key).state
        }
        guard !isSuperseded(since: generation) else { return try await refreshState() }
        guard state != .unlocked else { return nil }
        try await store.deleteSession()
        return state == .locked ? .needsMasterPassword(.sessionRejected) : .needsOnboarding
    }

    /// For the background details step: folder and organization names, and `bw status`. The key stays in this file.
    func listNamesWithSession() async throws -> (folders: [VaultFolder], organizations: [VaultOrganization]) {
        try await withSession { try await $0.listNames(session: $1) }
    }

    func statusWithSession() async throws -> BWStatus {
        try await withSession { try await $0.status(session: $1) }
    }

    private func rebuild(afterSyncWith session: SessionKey, generation: Int) async throws {
        try await client.sync(session: session)
        // Cleared while `bw sync` ran: never list the decrypted vault for a session that is gone.
        guard generation == self.generation, !Task.isCancelled else { throw BWError.locked }
        updateSyncStatus { $0.activity = .refreshing }
        let rebuilt = try await client.listVault(session: session)
        guard generation == self.generation else { throw BWError.locked }
        index?.replaceEntries(rebuilt.entries, folders: rebuilt.folders, organizations: rebuilt.organizations)
    }

    private func install(_ key: SessionKey, entries: [VaultEntry], storedSessionCreatedAt: Date) {
        session = key
        index = SearchIndex(entries: entries)
        authenticatedAt = clock.now()
        self.storedSessionCreatedAt = storedSessionCreatedAt
        startWatchdog()
        // Search runs on the cache at once; `bw sync` follows in the background (spec 7.3).
        updateSyncStatus { $0 = SyncStatus(lastSyncedAt: account.lastSync) }
        startBackgroundSync(syncingFirst: true)
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        let interval = policyCheckInterval
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let manager = self, await manager.enforcePolicy() else { return }
            }
        }
    }

    /// Drops the session key, the index (with its copy boost) and background sync. Returns the cancelled background
    /// loop and the cancelled running sync, so "Lock and forget" and "Sign out" can wait for both.
    @discardableResult
    private func clear(because reason: String) -> (loop: Task<Void, Never>?, sync: Task<Void, any Error>?) {
        generation &+= 1
        let wasUnlocked = session != nil
        session = nil
        index = nil
        authenticatedAt = nil
        storedSessionCreatedAt = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        let pendingSync = syncTask
        pendingSync?.cancel()
        syncTask = nil
        let running = runningSync
        running?.cancel()
        runningSync = nil
        updateSyncStatus { $0 = SyncStatus() }
        if wasUnlocked {
            Self.logger.info("Session cleared: \(reason, privacy: .private)")
            clearedContinuation.yield()
        }
        return (pendingSync, running)
    }

    /// Clears the session, deletes the stored one, waits for a running sync to stop, then runs `command`. Throws the
    /// first failure only after every step has run.
    private func clearAndForget(_ command: (BWClient) async throws -> Void) async throws {
        let pending = clear(because: "forget")
        var failure: (any Error)?
        do {
            try await store.deleteSession()
        } catch {
            failure = error
        }
        await pending.loop?.value
        _ = await pending.sync?.result
        do {
            try await command(client)
        } catch {
            failure = failure ?? error
        }
        if let failure { throw failure }
    }

    private func withSession<T: Sendable>(
        _ body: (BWClient, SessionKey) async throws -> T
    ) async throws -> T {
        guard enforcePolicy(), let session else { throw BWError.locked }
        let generation = generation
        let result = try await body(client, session)
        guard generation == self.generation else { throw BWError.locked }
        return result
    }
}
