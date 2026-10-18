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
        case .notInstalled: String(localized: "Bitwarden CLI not found", bundle: .module)
        case .tooOld: String(localized: "Bitwarden CLI is out of date", bundle: .module)
        case .unsafeBinary: String(localized: "Bitwarden CLI isn’t safe to use", bundle: .module)
        }
    }

    public var message: String {
        switch self {
        case .notInstalled:
            String(
                localized: """
                    VaultLight uses the Bitwarden command-line tool for every vault action. Install it with Homebrew, \
                    then open this panel again.
                    """, bundle: .module)
        case .tooOld:
            String(
                localized: """
                    VaultLight needs Bitwarden CLI \(BWClient.minimumVersion.description) or later. Upgrade it with \
                    Homebrew, then open this panel again.
                    """, bundle: .module)
        case .unsafeBinary:
            String(
                localized: """
                    Another user could change the bw binary or a folder on its way, so VaultLight won’t run it. Fix \
                    its ownership and permissions, or choose another location in Settings.
                    """, bundle: .module)
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
                return String(
                    localized: "Looked in /opt/homebrew/bin and /usr/local/bin. A custom path can be set in Settings.",
                    bundle: .module)
            }
            return String(localized: "Looked at \(path). Change it in Settings.", bundle: .module)
        case .tooOld(let installed):
            return path.map { String(localized: "Found bw \(installed) at \($0).", bundle: .module) }
                ?? String(localized: "Found bw \(installed).", bundle: .module)
        case .unsafeBinary:
            return path.map { String(localized: "Refused \($0).", bundle: .module) }
                ?? String(localized: "Refused the bw at the configured location.", bundle: .module)
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
        case .timedOut: String(localized: "bw didn’t respond within 15 s", bundle: .module)
        case .offline: String(localized: "Can’t reach the Bitwarden server", bundle: .module)
        case .unknown: String(localized: "Something went wrong", bundle: .module)
        }
    }
}

extension MasterPasswordReason {
    /// The footer's reason (design 07).
    public var footer: String {
        switch self {
        case .noStoredSession: String(localized: "Master password required", bundle: .module)
        case .restarted: String(localized: "Master password required after restart", bundle: .module)
        case .storedSessionExpired: String(localized: "Stored session expired", bundle: .module)
        case .sessionRejected: String(localized: "Stored session no longer works", bundle: .module)
        }
    }

    /// The line under the field (design 07).
    public static func prompt(email: String?) -> String {
        email.map { String(localized: "Enter the master password for \($0).", bundle: .module) }
            ?? String(localized: "Enter your master password.", bundle: .module)
    }
}

/// Short durations for status lines ("expires in 6 days").
public enum RelativeTime {
    /// Whole units, rounded down, at least one minute.
    public static func duration(_ seconds: TimeInterval) -> String {
        // English singular and plural are separate keys, so the copy is right even where a toolchain doesn't apply
        // the catalog's plural variations (CI run 39160724989); the "%lld …" keys still carry them for translations.
        if seconds >= 86_400 {
            let days = Int(seconds / 86_400)
            return days == 1
                ? String(localized: "1 day", bundle: .module) : String(localized: "\(days) days", bundle: .module)
        }
        if seconds >= 3_600 {
            let hours = Int(seconds / 3_600)
            return hours == 1
                ? String(localized: "1 hour", bundle: .module) : String(localized: "\(hours) hours", bundle: .module)
        }
        let minutes = max(1, Int(seconds / 60))
        return minutes == 1
            ? String(localized: "1 minute", bundle: .module) : String(localized: "\(minutes) minutes", bundle: .module)
    }

    /// Abbreviated, for "synced 3 min ago" (design 13, 14).
    public static func ago(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: String(localized: "just now", bundle: .module)
        case ..<3_600: String(localized: "\(Int(seconds / 60)) min ago", bundle: .module)
        case ..<86_400: String(localized: "\(Int(seconds / 3_600)) h ago", bundle: .module)
        default: String(localized: "\(Int(seconds / 86_400)) d ago", bundle: .module)
        }
    }
}
