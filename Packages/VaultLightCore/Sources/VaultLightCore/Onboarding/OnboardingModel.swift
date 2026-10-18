import Foundation
import Observation

/// What onboarding needs from `bw` (spec 3.2, 7.2). `CLIOnboardingBackend` is the production type; screenshots
/// use a demo one, and tests run the real one against the fake `bw`.
public protocol OnboardingBackend: Sendable {
    func configServer(_ url: URL) async throws
    func loginPassword(email: String, password: String, twoFactor: BWTwoFactor?) async throws
    func loginAPIKey(clientID: String, clientSecret: String) async throws
    /// `bw status` after sign-in, for the account's email.
    func status() async throws -> BWStatus
    /// `bw unlock`, then the Keychain and the index (spec 3.2 steps 3–4).
    func unlock(masterPassword: String, progress: @escaping @Sendable (UnlockProgress) -> Void) async throws
        -> VaultState
    func logout() async throws
}

/// Onboarding over the app's `BWClient` and `SessionManager`.
public struct CLIOnboardingBackend: OnboardingBackend {
    let client: BWClient
    let session: SessionManager

    public init(client: BWClient, session: SessionManager) {
        self.client = client
        self.session = session
    }

    public func configServer(_ url: URL) async throws { try await client.configServer(url) }

    public func loginPassword(email: String, password: String, twoFactor: BWTwoFactor?) async throws {
        try await client.loginPassword(email: email, password: password, twoFactor: twoFactor)
    }

    public func loginAPIKey(clientID: String, clientSecret: String) async throws {
        try await client.loginAPIKey(clientID: clientID, clientSecret: clientSecret)
    }

    public func status() async throws -> BWStatus { try await session.accountStatus() }

    public func unlock(masterPassword: String, progress: @escaping @Sendable (UnlockProgress) -> Void) async throws
        -> VaultState
    {
        try await session.unlock(masterPassword: masterPassword, progress: progress)
    }

    public func logout() async throws { try await client.logout() }
}

/// Onboarding in the panel (spec 3.2, designs 10–12 and 16): server → sign in (email and master password, with a
/// two-step code when asked, or a personal API key) → unlock → finishing.
///
/// Secrets come in as call parameters and go straight to `bw`. The one exception is the two-step step: `bw login`
/// needs the master password again with the code, so it is held from the first attempt until the code is accepted,
/// Back, the panel closing or a restart, whichever comes first. The API key is never held.
@MainActor
@Observable
public final class OnboardingModel {
    public private(set) var step = Step.server
    public var serverOption = ServerOption.bitwardenUS
    public var selfHostedAddress = ""
    public var method = Method.emailPassword
    public var email = ""
    /// The server `bw` was configured with.
    public private(set) var configuredServer: ServerChoice?
    public private(set) var signedInEmail: String?
    public private(set) var failure: Failure?
    public private(set) var isBusy = false
    public private(set) var twoFactorMethod = BWTwoFactor.Method.authenticator
    public private(set) var emailCodeSent = false
    public private(set) var checklist = Checklist()

    /// The master password, during the two-step step only.
    @ObservationIgnored private var pendingPassword: String?
    @ObservationIgnored private let backend: any OnboardingBackend

    public init(backend: any OnboardingBackend) {
        self.backend = backend
    }

    /// Whether the master password is held for the two-step step.
    public var holdsPassword: Bool { pendingPassword != nil }

    /// The server the server step would configure.
    public var chosenServer: ServerChoice {
        switch serverOption {
        case .bitwardenUS: .bitwardenUS
        case .bitwardenEU: .bitwardenEU
        case .selfHosted: .selfHosted(selfHostedAddress)
        }
    }

    // MARK: Lifecycle

    /// Back to the server step with nothing kept, after Sign Out (spec 3.5).
    public func restart() {
        dropPassword()
        step = .server
        serverOption = .bitwardenUS
        selfHostedAddress = ""
        method = .emailPassword
        email = ""
        configuredServer = nil
        signedInEmail = nil
        failure = nil
        checklist = Checklist()
    }

    /// At sign-in with a server already configured, after a server change in Settings (spec 8).
    public func resume(signInWith server: ServerChoice) {
        restart()
        switch server {
        case .bitwardenUS: serverOption = .bitwardenUS
        case .bitwardenEU: serverOption = .bitwardenEU
        case .selfHosted(let address):
            serverOption = .selfHosted
            selfHostedAddress = address
        }
        configuredServer = server
        step = .signIn
    }

    /// The panel closed. Progress is kept (design 12 "Esc"), except the held master password: the two-step step
    /// goes back to sign-in.
    public func panelDidClose() {
        if step == .twoFactor {
            dropPassword()
            step = .signIn
        }
        failure = nil
    }

    public func clearFailure() {
        failure = nil
    }

    public func back() async {
        guard !isBusy else { return }
        failure = nil
        switch step {
        case .server, .finishing:
            break
        case .signIn:
            step = .server
        case .twoFactor:
            dropPassword()
            step = .signIn
        case .unlock:
            // Signed in but locked: sign out of `bw`, so the next sign-in starts clean.
            await run {
                try await self.backend.logout()
                self.signedInEmail = nil
                self.step = .signIn
            }
        }
    }

    // MARK: Steps

    /// Runs `bw config server` (design 10).
    public func continueFromServer() async {
        guard step == .server, !isBusy else { return }
        let server = chosenServer
        guard let url = server.url else {
            failure = .invalidServerURL
            return
        }
        await run {
            try await self.backend.configServer(url)
            self.configuredServer = server
            self.step = .signIn
        }
    }

    /// Email and master password (design 11 state 1).
    public func signIn(password: String) async {
        guard step == .signIn, !isBusy else { return }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        await run {
            do {
                try await self.backend.loginPassword(email: email, password: password, twoFactor: nil)
            } catch BWError.twoFactorRequired {
                self.pendingPassword = password
                self.twoFactorMethod = .authenticator
                self.emailCodeSent = false
                self.step = .twoFactor
                return
            }
            await self.signedIn()
        }
    }

    /// Personal API key (design 11 state 3). The key is used for this call only.
    public func signIn(clientID: String, clientSecret: String) async {
        guard step == .signIn, !isBusy else { return }
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        await run {
            try await self.backend.loginAPIKey(clientID: clientID, clientSecret: clientSecret)
            await self.signedIn()
        }
    }

    /// The six-digit two-step code (design 11 state 2).
    public func verify(code: String) async {
        guard step == .twoFactor, !isBusy, let password = pendingPassword else { return }
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            failure = codeFailure
            return
        }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = twoFactorMethod
        await run {
            do {
                try await self.backend.loginPassword(
                    email: email, password: password, twoFactor: BWTwoFactor(method: method, code: code))
            } catch BWError.invalidTwoFactorCode, BWError.twoFactorRequired {
                self.failure = self.codeFailure
                return
            }
            self.dropPassword()
            await self.signedIn()
        }
    }

    /// "Send a code by email": the login again with the email method and no code, so the server sends one.
    public func sendCodeByEmail() async {
        guard step == .twoFactor, !isBusy, let password = pendingPassword else { return }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        await run {
            do {
                try await self.backend.loginPassword(
                    email: email, password: password, twoFactor: BWTwoFactor(method: .email, code: nil))
            } catch BWError.twoFactorRequired {
                self.twoFactorMethod = .email
                self.emailCodeSent = true
                return
            }
            self.dropPassword()
            await self.signedIn()
        }
    }

    /// The master password after sign-in (design 12). Shows the finishing checklist while `bw` works; returns
    /// whether the vault is unlocked.
    public func unlock(masterPassword: String) async -> Bool {
        guard step == .unlock, !isBusy else { return false }
        checklist = Checklist()
        step = .finishing
        var unlocked = false
        // The steps arrive from the session's actor; the stream keeps them in order, and is drained before return.
        let (steps, continuation) = AsyncStream.makeStream(of: UnlockProgress.self)
        let recorder = Task { @MainActor [weak self] in
            for await progress in steps { self?.record(progress) }
        }
        defer { continuation.finish() }
        await run {
            do {
                let state = try await self.backend.unlock(masterPassword: masterPassword) { continuation.yield($0) }
                continuation.finish()
                await recorder.value
                unlocked = state == .unlocked
            } catch BWError.invalidPassword {
                self.step = .unlock
                self.failure = .wrongMasterPassword
                return
            } catch {
                self.step = .unlock
                throw error
            }
        }
        if unlocked { checklist.indexBuilt = true }
        return unlocked
    }

    // MARK: Private

    private var codeFailure: Failure { twoFactorMethod == .email ? .wrongEmailCode : .wrongCode }

    private func record(_ progress: UnlockProgress) {
        switch progress {
        case .vaultUnlocked: checklist.vaultUnlocked = true
        case .sessionSaved(let saved): checklist.sessionSaved = saved
        case .indexBuilt(let logins):
            checklist.vaultUnlocked = true
            checklist.logins = logins
            checklist.indexBuilt = true
        }
    }

    /// After a successful login: the account's email, then the unlock step (spec 3.2 step 3).
    private func signedIn() async {
        failure = nil
        signedInEmail = (try? await backend.status())?.userEmail ?? (method == .emailPassword ? email : nil)
        step = .unlock
    }

    /// Runs one `bw` step with the busy flag, mapping a failure to fixed copy. A network failure on a self-hosted
    /// server sends the user back to the address (design 16 state 2): `bw config server` itself never connects.
    private func run(_ body: () async throws -> Void) async {
        isBusy = true
        failure = nil
        defer { isBusy = false }
        do {
            try await body()
        } catch {
            let mapped = Failure(error)
            if mapped == .offline, case .selfHosted = configuredServer, step == .signIn || step == .twoFactor {
                dropPassword()
                step = .server
                failure = .serverUnreachable
            } else {
                failure = mapped
            }
        }
    }

    private func dropPassword() {
        pendingPassword = nil
        emailCodeSent = false
        twoFactorMethod = .authenticator
    }
}

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
