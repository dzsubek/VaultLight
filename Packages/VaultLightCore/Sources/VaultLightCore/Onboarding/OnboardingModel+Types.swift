import Foundation

extension OnboardingModel {
    public enum Step: Sendable, Equatable {
        case server
        case signIn
        case twoFactor
        case unlock
        case finishing
    }

    public enum ServerOption: Sendable, Equatable, CaseIterable {
        case bitwardenUS
        case bitwardenEU
        case selfHosted
    }

    public enum Method: Sendable, Equatable {
        case emailPassword
        case apiKey
    }

    /// Fixed copy only (designs 16): never `bw` output, which can name the account or the server.
    public enum Failure: Sendable, Equatable {
        case invalidServerURL
        case serverUnreachable
        case wrongCredentials
        case wrongAPIKey
        case wrongCode
        case wrongEmailCode
        case wrongMasterPassword
        /// The two-step step waited longer than `passwordHoldLimit`.
        case twoFactorExpired
        case offline
        case timedOut
        case failed

        public var message: String {
            switch self {
            case .invalidServerURL: "Enter the server’s full address, like https://vault.example.com."
            case .serverUnreachable: "Can’t reach this server. Check the address and that the server is running."
            case .wrongCredentials: "Email or master password is incorrect."
            case .wrongAPIKey: "client_id or client_secret is incorrect."
            case .wrongCode: "That code didn’t work. Enter the current code from your app."
            case .wrongEmailCode: "That code didn’t work. Enter the code from the latest email."
            case .wrongMasterPassword: "Wrong master password. Try again."
            case .twoFactorExpired: "VaultLight keeps your master password for 5 minutes at most. Sign in again."
            case .offline: "Can’t reach Bitwarden. Check your internet connection."
            case .timedOut: "bw didn’t respond within 15 s. Try again."
            case .failed: "That didn’t work. Try again."
            }
        }

        /// Only the error's case decides it.
        init(_ error: any Error) {
            switch error as? BWError {
            case .invalidPassword: self = .wrongCredentials
            case .invalidAPIKey: self = .wrongAPIKey
            case .invalidTwoFactorCode: self = .wrongCode
            case .network: self = .offline
            case .timeout: self = .timedOut
            case .invalidArgument: self = .invalidServerURL
            default: self = .failed
            }
        }
    }

    /// The finishing rows (design 12 state 2).
    public struct Checklist: Sendable, Equatable {
        public var vaultUnlocked = false
        /// `nil` until known; `false` means Touch ID won't be offered next time.
        public var sessionSaved: Bool?
        public var logins: Int?
        public var indexBuilt = false
    }
}
