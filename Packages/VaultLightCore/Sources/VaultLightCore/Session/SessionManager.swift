import Foundation
import os

/// What the panel shows (spec 3.1). A missing or unsafe `bw` is reported by the `BWError` a call throws.
public enum VaultState: Sendable, Equatable {
    /// `bw` is logged out: onboarding (spec 3.2).
    case needsOnboarding
    /// Locked with no usable stored session: the master password field.
    case needsMasterPassword(MasterPasswordReason)
    /// Locked, and a stored session within its maximum age exists: "Touch ID to unlock".
    case storedSessionAvailable
    /// Search is ready.
    case unlocked
}

/// Why the master password is needed, for the footer (design Screen 7).
public enum MasterPasswordReason: Sendable, Equatable {
    case noStoredSession
    /// The stored session was created before the last restart (spec 3.5).
    case restarted
    /// The stored session passed its maximum age.
    case storedSessionExpired
    /// `bw` no longer accepted the stored session (spec 3.4 step 5).
    case sessionRejected
}

/// System notifications that clear the in-memory session (spec 3.5). The app maps NSWorkspace and distributed
/// notifications to these; tests yield them directly.
public enum SystemEvent: Sendable {
    case willSleep
    case screenLocked
    /// Fast user switching moved this login session to the background.
    case sessionResigned
}

/// Owns the unlocked session (spec 2, 3.4, 3.5): the session key, the search index built from it, and background
/// sync. Only this type reads the session store, and the session key never leaves it.
///
/// A watchdog checks the policy every `policyCheckInterval` while unlocked, so idle time and lifetimes end the
/// session even when nothing calls in: opening the panel is itself input and resets the idle time.
///
/// Every clear bumps `generation`. Work that awaits (an unlock, a sync, a copy) checks it before using its result,
/// so nothing finished after a lock can bring the session or index back.
public actor SessionManager {
    private static let logger = Logger(subsystem: "com.vaultlight.core", category: "session")

    private let client: BWClient
    private let store: any SessionStore
    private let clock: SessionClock
    private let policyCheckInterval: Duration
    private var policy: SessionPolicy
    private var backgroundSyncInterval: Duration?

    private var session: SessionKey?
    private var index: SearchIndex?
    private var authenticatedAt: Date?
    /// Creation date of the stored session this one came from; its maximum age also ends the in-memory session.
    private var storedSessionCreatedAt: Date?
    private var generation = 0
    private var syncTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private let clearedContinuation: AsyncStream<Void>.Continuation

    /// Yields each time an unlocked session is cleared, for whatever reason, so the panel can close (spec 4.3).
    public nonisolated let sessionCleared: AsyncStream<Void>

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
    }

    deinit {
        syncTask?.cancel()
        eventTask?.cancel()
        watchdogTask?.cancel()
        clearedContinuation.finish()
    }

    public var isUnlocked: Bool { session != nil }

    public func updateSettings(_ settings: SessionSettings) {
        policy.settings = settings
    }

    /// Restarts background sync with the new interval while unlocked.
    public func setBackgroundSyncInterval(_ interval: Duration?) {
        backgroundSyncInterval = interval
        if session != nil { startBackgroundSync() }
    }

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
        return try await lockedState(storedSession: storedSessionVerdict())
    }

    /// `bw unlock` with the master password, then stores the session key (spec 3.2 steps 3–4). The password lives
    /// only for this call.
    public func unlock(masterPassword: String) async throws -> VaultState {
        let generation = generation
        let key = try await client.unlock(password: masterPassword)
        let index = try await buildIndex(session: key)
        guard generation == self.generation else { return try await refreshState() }
        let createdAt = clock.now()
        do {
            try await store.saveSession(key, createdAt: createdAt)
        } catch {
            Self.logger.error("Storing the session failed: \(String(describing: error), privacy: .private)")
        }
        guard generation == self.generation else {
            // A lock or "Lock and forget" ran while the key was being stored.
            do {
                try await store.deleteSession()
            } catch {
                Self.logger.error("Deleting the session failed: \(String(describing: error), privacy: .private)")
            }
            return try await refreshState()
        }
        install(key, index: index, storedSessionCreatedAt: createdAt)
        return .unlocked
    }

    /// Reads the stored session behind Touch ID and confirms `bw` still accepts it (spec 3.4 steps 3–5).
    /// Throws `SessionStoreError.cancelled` when the user dismisses the sheet; the stored session is kept.
    public func unlockWithStoredSession(reason: String) async throws -> VaultState {
        let generation = generation
        guard let createdAt = try await store.storedSessionDate() else {
            return try await lockedState(storedSession: nil)
        }
        let verdict = try await storedSessionVerdict(createdAt: createdAt)
        guard verdict == .valid else { return try await lockedState(storedSession: verdict) }
        let key: SessionKey
        do {
            key = try await store.readSession(reason: reason)
        } catch SessionStoreError.notFound {
            return try await refreshState()
        }
        switch try await client.status(session: key).state {
        case .unlocked:
            break
        case .locked:
            try await store.deleteSession()
            return .needsMasterPassword(.sessionRejected)
        case .unauthenticated:
            try await store.deleteSession()
            return .needsOnboarding
        }
        let index = try await buildIndex(session: key)
        guard generation == self.generation else { return try await refreshState() }
        install(key, index: index, storedSessionCreatedAt: createdAt)
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
        try await clearAndForget { try await $0.lock() }
    }

    /// "Sign out" (spec 3.5): the local session goes first, so a failed `bw logout` leaves nothing usable. Clears
    /// the in-memory session and index, deletes the stored session, stops background sync, then runs `bw logout`.
    ///
    /// If `bw logout` fails, `bw lock` runs too, which invalidates every session key, including one whose Keychain
    /// delete failed. The error is still thrown: `bw` is then logged in, so onboarding can't start yet.
    public func signOut() async throws -> VaultState {
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

    /// `bw sync`, then rebuilds the index, keeping the copy boost (spec 2.1, 7.3).
    public func sync() async throws {
        try await withSession { client, session in
            try await client.sync(session: session)
            let generation = self.generation
            let rebuilt = try await self.buildIndex(session: session)
            guard generation == self.generation else { throw BWError.locked }
            self.index?.replaceEntries(rebuilt.entries, folders: rebuilt.folders, organizations: rebuilt.organizations)
        }
    }

    /// What `bw list` returned, decoded to metadata only.
    fileprivate struct Listing {
        let entries: [VaultEntry]
        let folders: [VaultFolder]
        let organizations: [VaultOrganization]
    }
}

extension SessionManager {
    // MARK: Private

    /// The stored session's verdict, or `nil` when there is none. An expired one is deleted and `bw` locked.
    private func storedSessionVerdict() async throws -> SessionVerdict? {
        guard let createdAt = try await store.storedSessionDate() else { return nil }
        return try await storedSessionVerdict(createdAt: createdAt)
    }

    private func storedSessionVerdict(createdAt: Date) async throws -> SessionVerdict {
        let verdict = policy.storedSession(createdAt: createdAt, now: clock.now(), bootTime: clock.bootTime())
        if verdict != .valid {
            Self.logger.info("Stored session expired: \(String(describing: verdict), privacy: .private)")
            try await store.deleteSession()
            do {
                try await client.lock()
            } catch {
                Self.logger.error("bw lock failed: \(String(describing: error), privacy: .private)")
            }
        }
        return verdict
    }

    /// The locked state for a stored-session verdict. Asks `bw` only when there is no usable stored session.
    private func lockedState(storedSession verdict: SessionVerdict?) async throws -> VaultState {
        let reason: MasterPasswordReason
        switch verdict {
        case .valid: return .storedSessionAvailable
        case nil: reason = .noStoredSession
        case .expiredByRestart: reason = .restarted
        case .expiredByAge, .expiredByLifetime, .expiredByIdle: reason = .storedSessionExpired
        }
        return try await client.status().state == .unauthenticated ? .needsOnboarding : .needsMasterPassword(reason)
    }

    private func buildIndex(session: SessionKey) async throws -> Listing {
        let listed: [VaultEntry.Listed] = try await client.listItems(session: session)
        let folders: [VaultFolder] = try await client.listFolders(session: session)
        let organizations: [VaultOrganization] = try await client.listOrganizations(session: session)
        return Listing(entries: listed.compactMap(\.entry), folders: folders, organizations: organizations)
    }

    private func install(_ key: SessionKey, index: Listing, storedSessionCreatedAt: Date) {
        session = key
        self.index = SearchIndex(entries: index.entries, folders: index.folders, organizations: index.organizations)
        authenticatedAt = clock.now()
        self.storedSessionCreatedAt = storedSessionCreatedAt
        startWatchdog()
        startBackgroundSync()
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

    /// Drops the session key, the index (with its copy boost) and background sync. Returns the cancelled sync task.
    @discardableResult
    private func clear(because reason: String) -> Task<Void, Never>? {
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
        if wasUnlocked {
            Self.logger.info("Session cleared: \(reason, privacy: .private)")
            clearedContinuation.yield()
        }
        return pendingSync
    }

    /// Clears the session, deletes the stored one, waits for a running sync to stop, then runs `command`. Throws the
    /// first failure only after every step has run.
    private func clearAndForget(_ command: (BWClient) async throws -> Void) async throws {
        let pendingSync = clear(because: "forget")
        var failure: (any Error)?
        do {
            try await store.deleteSession()
        } catch {
            failure = error
        }
        await pendingSync?.value
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

    private func startBackgroundSync() {
        syncTask?.cancel()
        syncTask = nil
        guard let interval = backgroundSyncInterval, session != nil else { return }
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await self?.sync()
                } catch {
                    Self.logger.error("Background sync failed: \(String(describing: error), privacy: .private)")
                }
                try? await Task.sleep(for: interval)
            }
        }
    }
}
