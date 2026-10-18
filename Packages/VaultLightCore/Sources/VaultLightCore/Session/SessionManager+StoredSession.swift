import Foundation

/// The stored session's limits and the locked state (spec 3.4, 3.5).
extension SessionManager {
    /// The stored session's verdict, or `nil` when there is none. An expired one is deleted and `bw` locked. A
    /// session whose date isn't readable yet is `.valid`: Touch ID decides. A store that can't be read at all is
    /// deleted and treated as none, so the master password is still possible.
    func storedSessionVerdict() async throws -> SessionVerdict? {
        let stored: StoredSession
        do {
            stored = try await store.storedSession()
        } catch {
            Self.logger.error("Reading the stored session failed: \(diagnosticKind(of: error), privacy: .private)")
            try? await store.deleteSession()
            await lockBW()
            return nil
        }
        switch stored {
        case .none:
            account.storedSessionExpiresAt = nil
            return nil
        case .dateUnknown: return .valid
        case .created(let createdAt): return try await storedSessionVerdict(createdAt: createdAt)
        }
    }

    func storedSessionVerdict(createdAt: Date) async throws -> SessionVerdict {
        let verdict = policy.storedSession(createdAt: createdAt, now: clock.now(), bootTime: clock.bootTime())
        account.storedSessionExpiresAt =
            verdict == .valid ? createdAt.addingTimeInterval(policy.settings.storedMaximumAge.seconds) : nil
        if verdict != .valid {
            Self.logger.info("Stored session expired: \(String(describing: verdict), privacy: .private)")
            try await store.deleteSession()
            await lockBW()
        }
        return verdict
    }

    /// `bw lock`, which pairs with every delete of the stored session (spec 3.5). A failure is only logged.
    func lockBW() async {
        do {
            try await client.lock()
        } catch {
            Self.logger.error("bw lock failed: \(diagnosticKind(of: error), privacy: .private)")
        }
    }

    /// The locked state for a stored-session verdict. Asks `bw` only when there is no usable stored session.
    func lockedState(storedSession verdict: SessionVerdict?) async throws -> VaultState {
        let reason: MasterPasswordReason
        switch verdict {
        case .valid: return .storedSessionAvailable
        case nil: reason = .noStoredSession
        case .expiredByRestart: reason = .restarted
        case .expiredByAge, .expiredByLifetime, .expiredByIdle: reason = .storedSessionExpired
        }
        try await client.checkVersion()
        let status = try await client.status()
        account.remember(status)
        return status.state == .unauthenticated ? .needsOnboarding : .needsMasterPassword(reason)
    }
}
