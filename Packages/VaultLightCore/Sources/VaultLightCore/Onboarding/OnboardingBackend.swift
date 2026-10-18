import Foundation

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
