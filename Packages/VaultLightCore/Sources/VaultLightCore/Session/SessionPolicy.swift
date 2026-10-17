import Foundation

/// The session rows of spec 8, with the spec's defaults. No secrets.
public struct SessionSettings: Sendable, Equatable {
    public enum StoredMaximumAge: Sendable, CaseIterable {
        case oneDay, sevenDays, thirtyDays

        public var seconds: TimeInterval {
            switch self {
            case .oneDay: 86_400
            case .sevenDays: 7 * 86_400
            case .thirtyDays: 30 * 86_400
            }
        }
    }

    public enum InMemoryLifetime: Sendable, CaseIterable {
        case fifteenMinutes, oneHour, eightHours

        public var seconds: TimeInterval {
            switch self {
            case .fifteenMinutes: 15 * 60
            case .oneHour: 3_600
            case .eightHours: 8 * 3_600
            }
        }
    }

    public enum IdleLock: Sendable, CaseIterable {
        case off, fiveMinutes, fifteenMinutes, thirtyMinutes

        /// `nil` when idle locking is off.
        public var seconds: TimeInterval? {
            switch self {
            case .off: nil
            case .fiveMinutes: 5 * 60
            case .fifteenMinutes: 15 * 60
            case .thirtyMinutes: 30 * 60
            }
        }
    }

    public var storedMaximumAge: StoredMaximumAge
    public var requireMasterPasswordAfterRestart: Bool
    public var inMemoryLifetime: InMemoryLifetime
    public var idleLock: IdleLock

    public init(
        storedMaximumAge: StoredMaximumAge = .sevenDays, requireMasterPasswordAfterRestart: Bool = true,
        inMemoryLifetime: InMemoryLifetime = .eightHours, idleLock: IdleLock = .fifteenMinutes
    ) {
        self.storedMaximumAge = storedMaximumAge
        self.requireMasterPasswordAfterRestart = requireMasterPasswordAfterRestart
        self.inMemoryLifetime = inMemoryLifetime
        self.idleLock = idleLock
    }
}

public enum SessionVerdict: Sendable, Equatable {
    case valid
    /// The stored session is past its maximum age.
    case expiredByAge
    /// The stored session was created before the last boot, and the master password is required after a restart.
    case expiredByRestart
    /// The in-memory session outlived its lifetime since the last Touch ID or master-password check.
    case expiredByLifetime
    /// The Mac has had no input for longer than the idle limit.
    case expiredByIdle
}

/// Decides whether a session may still be used (spec 3.5). Pure: callers pass the instants, so tests control time.
/// A time in the future counts as expired, so a wrong clock can't keep a session alive.
public struct SessionPolicy: Sendable {
    public var settings: SessionSettings

    public init(settings: SessionSettings) {
        self.settings = settings
    }

    /// The Keychain session. `bootTime` is `nil` when it is unknown, which counts as a restart.
    public func storedSession(createdAt: Date, now: Date, bootTime: Date?) -> SessionVerdict {
        if settings.requireMasterPasswordAfterRestart, createdAt < (bootTime ?? .distantFuture) {
            return .expiredByRestart
        }
        let age = now.timeIntervalSince(createdAt)
        return age < 0 || age >= settings.storedMaximumAge.seconds ? .expiredByAge : .valid
    }

    /// The in-memory session. `idleTime` is how long the Mac has had no keyboard or mouse input.
    public func inMemorySession(authenticatedAt: Date, now: Date, idleTime: TimeInterval) -> SessionVerdict {
        let age = now.timeIntervalSince(authenticatedAt)
        if age < 0 || age >= settings.inMemoryLifetime.seconds { return .expiredByLifetime }
        if let limit = settings.idleLock.seconds, idleTime >= limit { return .expiredByIdle }
        return .valid
    }
}
