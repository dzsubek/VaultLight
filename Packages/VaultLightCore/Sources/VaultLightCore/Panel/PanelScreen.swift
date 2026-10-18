import Foundation

/// What the panel shows: one screen per vault state (spec 3.1) and per error that stops the panel (spec 7.4). Copy
/// is fixed here; no raw `bw` output or vault content ever reaches it.
public enum PanelScreen: Sendable, Equatable {
    /// The vault state is being read.
    case checking
    case search
    /// Locked, stored session within its maximum age: "Touch ID to unlock" (design 06).
    case touchID
    /// Locked, no usable stored session (design 07).
    case masterPassword(MasterPasswordReason)
    /// Logged out: onboarding (spec 3.2, designs 10–12).
    case onboarding
    /// `bw` is missing, too old or unsafe (designs 09, 16).
    case setupProblem(SetupProblem)
    case failure(PanelFailure)

    public init(_ state: VaultState) {
        switch state {
        case .needsOnboarding: self = .onboarding
        case .needsMasterPassword(let reason): self = .masterPassword(reason)
        case .storedSessionAvailable: self = .touchID
        case .unlocked: self = .search
        }
    }

    /// The screen for a failed state check or unlock. Only the error's case decides it.
    public init(error: any Error) {
        switch error as? BWError {
        case .notInstalled: self = .setupProblem(.notInstalled)
        case .tooOld(let installed): self = .setupProblem(.tooOld(installed: installed))
        case .unsafeBinary: self = .setupProblem(.unsafeBinary)
        case .unauthenticated: self = .onboarding
        case .locked: self = .masterPassword(.sessionRejected)
        case .timeout: self = .failure(.timedOut)
        case .network: self = .failure(.offline)
        default: self = .failure(.unknown)
        }
    }
}

/// `bw` can't be used (spec 3.1 "`bw` not found", 7.1 pinned binary, 7.4 "too old"). The same layout for each:
/// a title, an explanation, the Homebrew command that fixes it (none for an unsafe binary) and where VaultLight
/// looked.
public enum SetupProblem: Sendable, Equatable {
    case notInstalled
    case tooOld(installed: String)
    case unsafeBinary

    public var title: String {
        switch self {
        case .notInstalled: "Bitwarden CLI not found"
        case .tooOld: "Bitwarden CLI is out of date"
        case .unsafeBinary: "Bitwarden CLI isn’t safe to use"
        }
    }

    public var message: String {
        switch self {
        case .notInstalled:
            "VaultLight uses the Bitwarden command-line tool for every vault action. Install it with Homebrew, "
                + "then open this panel again."
        case .tooOld:
            "VaultLight needs Bitwarden CLI \(BWClient.minimumVersion) or later. Upgrade it with Homebrew, then "
                + "open this panel again."
        case .unsafeBinary:
            "Another user could change the bw binary or a folder on its way, so VaultLight won’t run it. Fix its "
                + "ownership and permissions, or choose another location in Settings."
        }
    }

    /// The command to copy; `nil` when no command fixes it.
    public var command: String? {
        switch self {
        case .notInstalled: "brew install bitwarden-cli"
        case .tooOld: "brew upgrade bitwarden-cli"
        case .unsafeBinary: nil
        }
    }

    /// The small print under the command. `path` is the configured `bw` path (for a missing one) or the binary that
    /// was found.
    public func detail(path: String?) -> String {
        switch self {
        case .notInstalled:
            guard let path else {
                return "Looked in /opt/homebrew/bin and /usr/local/bin. A custom path can be set in Settings."
            }
            return "Looked at \(path). Change it in Settings."
        case .tooOld(let installed):
            return path.map { "Found bw \(installed) at \($0)." } ?? "Found bw \(installed)."
        case .unsafeBinary:
            return path.map { "Refused \($0)." } ?? "Refused the bw at the configured location."
        }
    }
}

/// A failure that isn't a setup problem, with fixed copy.
public enum PanelFailure: Sendable, Equatable {
    case timedOut
    case offline
    case unknown

    public var message: String {
        switch self {
        case .timedOut: "bw didn’t respond within 15 s"
        case .offline: "Can’t reach the Bitwarden server"
        case .unknown: "Something went wrong"
        }
    }
}

extension MasterPasswordReason {
    /// The footer's reason (design 07).
    public var footer: String {
        switch self {
        case .noStoredSession: "Master password required"
        case .restarted: "Master password required after restart"
        case .storedSessionExpired: "Stored session expired"
        case .sessionRejected: "Stored session no longer works"
        }
    }

    /// The line under the field (design 07).
    public static func prompt(email: String?) -> String {
        email.map { "Enter the master password for \($0)." } ?? "Enter your master password."
    }
}

/// The footer's warning after a failed sync (spec 7.3, 7.4 "Offline"): search keeps working on the cached vault.
public enum SyncNotice: Sendable, Equatable {
    case offline
    case failed

    public init(error: any Error) {
        self = (error as? BWError) == .network ? .offline : .failed
    }

    public var message: String {
        switch self {
        case .offline: "Offline · showing the cached vault"
        case .failed: "Sync failed"
        }
    }
}

/// Short durations for status lines ("expires in 6 days").
public enum RelativeTime {
    /// Whole units, rounded down, at least one minute.
    public static func duration(_ seconds: TimeInterval) -> String {
        let units: [(TimeInterval, String)] = [(86_400, "day"), (3_600, "hour"), (60, "minute")]
        for (size, name) in units where seconds >= size {
            let count = Int(seconds / size)
            return "\(count) \(name)\(count == 1 ? "" : "s")"
        }
        return "1 minute"
    }
}
