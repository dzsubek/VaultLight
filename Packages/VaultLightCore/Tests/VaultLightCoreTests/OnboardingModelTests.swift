import Foundation
import Testing

@testable import VaultLightCore

/// Onboarding (spec 3.2, designs 10–12, 16) through the real `BWClient` and `SessionManager`, against the fake `bw`
/// and an in-memory session store.
@MainActor
@Suite("Onboarding", .serialized)
struct OnboardingModelTests {
    let fake: FakeBW
    let store = InMemorySessionStore()
    let session: SessionManager
    let model: OnboardingModel

    init() throws {
        fake = try FakeBW()
        let client = fake.client()
        session = SessionManager(client: client, store: store, clock: TestClock().sessionClock)
        model = OnboardingModel(backend: CLIOnboardingBackend(client: client, session: session))
    }

    /// argv of every `login` the fake saw.
    func logins() throws -> [[String]] {
        try fake.calls().compactMap { $0["argv"] as? [String] }.filter { $0.first == "login" }
    }

    func commands() throws -> [String] {
        try fake.calls().compactMap { ($0["argv"] as? [String])?.first }
    }

    /// Server chosen and configured, email method, email typed.
    func atSignIn(server: OnboardingModel.ServerOption = .bitwardenUS, address: String = "") async throws {
        model.serverOption = server
        model.selfHostedAddress = address
        await model.continueFromServer()
        try #require(model.step == .signIn)
        model.email = FakeBW.Defaults.email
    }

    @Test func startsAtTheServerStepWithBitwardenUS() {
        #expect(model.step == .server)
        #expect(model.serverOption == .bitwardenUS)
        #expect(model.method == .emailPassword)
        #expect(model.failure == nil)
    }

    @Test func serverStepConfiguresTheChosenServer() async throws {
        model.serverOption = .bitwardenEU
        await model.continueFromServer()
        #expect(model.step == .signIn)
        #expect(model.configuredServer == .bitwardenEU)
        #expect(try fake.lastArguments() == ["config", "server", "https://vault.bitwarden.eu", "--nointeraction"])
    }

    @Test func selfHostedAddressIsCheckedBeforeBWRuns() async throws {
        model.serverOption = .selfHosted
        for address in ["", "ftp://vault.home.arpa", "https://user:pw@vault.home.arpa", "https://vault.home.arpa/?a=b"]
        {
            model.selfHostedAddress = address
            await model.continueFromServer()
            #expect(model.step == .server)
            #expect(model.failure == .invalidServerURL)
        }
        #expect(try fake.calls().isEmpty)
        model.selfHostedAddress = "vault.home.arpa"
        await model.continueFromServer()
        #expect(model.step == .signIn)
        #expect(model.configuredServer == .selfHosted("vault.home.arpa"))
        #expect(try fake.lastArguments().contains("https://vault.home.arpa"))
    }

    @Test func emailSignInThenUnlockOpensTheVault() async throws {
        try await atSignIn()
        await model.signIn(password: FakeBW.Defaults.masterPassword)
        #expect(model.step == .unlock)
        #expect(model.signedInEmail == FakeBW.Defaults.email)
        #expect(
            try logins().last == [
                "login", FakeBW.Defaults.email, "--passwordenv", "VAULTLIGHT_MASTER_PASSWORD", "--nointeraction",
            ])

        #expect(await model.unlock(masterPassword: FakeBW.Defaults.masterPassword))
        #expect(model.step == .finishing)
        #expect(model.checklist.vaultUnlocked)
        #expect(model.checklist.sessionSaved == true)
        #expect((model.checklist.logins ?? 0) > 0)
        #expect(model.checklist.indexBuilt)
        #expect(await session.isUnlocked)
        #expect(await store.item != nil)
    }

    @Test func apiKeySignInThenUnlockOpensTheVault() async throws {
        try await atSignIn()
        model.method = .apiKey
        await model.signIn(clientID: FakeBW.Defaults.clientID, clientSecret: FakeBW.Defaults.clientSecret)
        #expect(model.step == .unlock)
        #expect(model.signedInEmail == FakeBW.Defaults.email)
        #expect(try logins().last == ["login", "--apikey", "--nointeraction"])
        #expect(await model.unlock(masterPassword: FakeBW.Defaults.masterPassword))
        #expect(await session.isUnlocked)
    }

    @Test func wrongPasswordKeepsTheEmailAndStaysOnSignIn() async throws {
        try await atSignIn()
        await model.signIn(password: "wrong password")
        #expect(model.step == .signIn)
        #expect(model.failure == .wrongCredentials)
        #expect(model.failure?.message == "Email or master password is incorrect.")
        #expect(model.email == FakeBW.Defaults.email)
        // Editing a field clears the message.
        model.clearFailure()
        #expect(model.failure == nil)
    }

    @Test func wrongAPIKeyStaysOnSignIn() async throws {
        try await atSignIn()
        model.method = .apiKey
        await model.signIn(clientID: FakeBW.Defaults.clientID, clientSecret: "wrong")
        #expect(model.step == .signIn)
        #expect(model.failure == .wrongAPIKey)
    }

    @Test func closingKeepsEveryOtherStep() async throws {
        try await atSignIn()
        model.panelDidClose()
        #expect(model.step == .signIn)
        model.method = .apiKey
        await model.signIn(clientID: FakeBW.Defaults.clientID, clientSecret: FakeBW.Defaults.clientSecret)
        model.panelDidClose()
        #expect(model.step == .unlock)
    }

    @Test func unreachableSelfHostedServerGoesBackToTheServerStep() async throws {
        try fake.configure(["offline": true])
        try await atSignIn(server: .selfHosted, address: "https://vault.home.arpa")
        await model.signIn(password: FakeBW.Defaults.masterPassword)
        #expect(model.step == .server)
        #expect(model.failure == .serverUnreachable)
        #expect(model.selfHostedAddress == "https://vault.home.arpa")
        #expect(model.failure?.message == "Can’t reach this server. Check the address and that the server is running.")
    }

    @Test func unreachableBitwardenStaysOnSignIn() async throws {
        try fake.configure(["offline": true])
        try await atSignIn()
        await model.signIn(password: FakeBW.Defaults.masterPassword)
        #expect(model.step == .signIn)
        #expect(model.failure == .offline)
    }

    @Test func wrongMasterPasswordOnUnlockStaysOnUnlock() async throws {
        try await atSignIn()
        model.method = .apiKey
        await model.signIn(clientID: FakeBW.Defaults.clientID, clientSecret: FakeBW.Defaults.clientSecret)
        #expect(await !model.unlock(masterPassword: "wrong"))
        #expect(model.step == .unlock)
        #expect(model.failure == .wrongMasterPassword)
        #expect(model.failure?.message == "Wrong master password. Try again.")
        #expect(await !session.isUnlocked)
    }

    @Test func backFromUnlockSignsOutOfBW() async throws {
        try await atSignIn()
        model.method = .apiKey
        await model.signIn(clientID: FakeBW.Defaults.clientID, clientSecret: FakeBW.Defaults.clientSecret)
        await model.back()
        #expect(model.step == .signIn)
        #expect(try commands().last == "logout")
        #expect(model.signedInEmail == nil)
    }

    @Test func backFromSignInReturnsToTheServerStep() async throws {
        try await atSignIn(server: .bitwardenEU)
        await model.back()
        #expect(model.step == .server)
        #expect(model.serverOption == .bitwardenEU)
    }

    @Test func restartAfterSignOutBeginsAtTheServerStep() async throws {
        try await atSignIn()
        model.restart()
        #expect(model.step == .server)
        #expect(model.email.isEmpty)
        #expect(model.configuredServer == nil)
    }

    @Test func serverChangeResumesAtSignInWithTheNewServer() async throws {
        model.resume(signInWith: .selfHosted("https://vault.home.arpa"))
        #expect(model.step == .signIn)
        #expect(model.configuredServer == .selfHosted("https://vault.home.arpa"))
        #expect(model.serverOption == .selfHosted)
        #expect(model.selfHostedAddress == "https://vault.home.arpa")
    }

    @Test func failuresHaveFixedCopy() {
        let all: [OnboardingModel.Failure] = [
            .invalidServerURL, .serverUnreachable, .wrongCredentials, .wrongAPIKey, .wrongCode, .wrongEmailCode,
            .wrongMasterPassword, .twoFactorExpired, .offline, .timedOut, .failed,
        ]
        #expect(Set(all.map(\.message)).count == all.count)
        #expect(OnboardingModel.Failure(BWError.unknown("tester@example.com secret")) == .failed)
    }
}

/// Records the durations an injected sleep was asked for, and returns at once.
final class DurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Duration] = []

    var values: [Duration] { lock.withLock { durations } }

    func append(_ duration: Duration) {
        lock.withLock { durations.append(duration) }
    }
}
