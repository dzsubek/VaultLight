import Foundation
import Testing

@testable import VaultLightCore

/// Spec 7.1 and 7.2, against the fake `bw`. The fake exits 99 when a secret is in argv and 98 when
/// `--nointeraction` is missing, so every successful call below also proves both rules for that command.
@Suite("BWClient")
struct BWClientTests {
    private struct Named: Decodable, Sendable {
        let id: String
        let name: String
    }

    private static let baseKeys: Set<String> = ["HOME", "PATH", "BITWARDENCLI_APPDATA_DIR"]

    private static let allSecrets = [
        FakeBW.Defaults.masterPassword, FakeBW.Defaults.sessionKey, FakeBW.Defaults.clientID,
        FakeBW.Defaults.clientSecret,
    ]

    /// argv of the last call holds no secret, anywhere inside an argument.
    private func expectNoSecretsInArguments(_ fake: FakeBW) throws {
        let arguments = try fake.lastArguments()
        #expect(!arguments.isEmpty)
        for secret in Self.allSecrets {
            #expect(!arguments.contains { $0.contains(secret) })
        }
        #expect(arguments.contains("--nointeraction"))
    }

    // MARK: Environment and arguments

    @Test func environmentIsTheBaseKeysPlusTheCallsSecret() throws {
        let fake = try FakeBW()
        let environment = BWClient.environment(
            searchPath: "/opt/homebrew/bin:/usr/bin:/bin", home: "/Users/x", dataDirectory: fake.dataDirectory,
            secrets: ["BW_SESSION": "s", "HOME": "/attacker"])
        #expect(
            environment == [
                "HOME": "/Users/x", "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
                "BITWARDENCLI_APPDATA_DIR": fake.dataDirectory.path, "BW_SESSION": "s",
            ])
    }

    @Test func callsWithoutSecretsGetOnlyTheBaseEnvironment() async throws {
        let fake = try FakeBW()
        let client = fake.client()
        _ = try await client.version()
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys)
        #expect(try fake.lastArguments() == ["--version", "--nointeraction"])
        _ = try await client.status()
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys)
        try await client.configServer(#require(URL(string: "https://vault.example.test")))
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys)
        #expect(try fake.lastArguments() == ["config", "server", "https://vault.example.test", "--nointeraction"])
        try await client.lock()
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys)
        try await client.logout()
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys)
        #expect(try fake.lastArguments() == ["logout", "--nointeraction"])
    }

    @Test func statusWithSessionPassesItInBWSession() async throws {
        let fake = try FakeBW.unlocked()
        let status = try await fake.client().status(session: FakeBW.session)
        #expect(status.state == .unlocked)
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys.union(["BW_SESSION"]))
        try expectNoSecretsInArguments(fake)
    }

    @Test func loginAPIKeyPassesTheKeyInTheEnvironment() async throws {
        let fake = try FakeBW()
        let client = fake.client()
        try await client.loginAPIKey(clientID: FakeBW.Defaults.clientID, clientSecret: FakeBW.Defaults.clientSecret)
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys.union(["BW_CLIENTID", "BW_CLIENTSECRET"]))
        #expect(try fake.lastArguments() == ["login", "--apikey", "--nointeraction"])
        try expectNoSecretsInArguments(fake)
        #expect(try await client.status().state == .locked)
    }

    @Test func loginPasswordPassesThePasswordThroughPasswordEnv() async throws {
        let fake = try FakeBW()
        let client = fake.client()
        try await client.loginPassword(email: FakeBW.Defaults.email, password: FakeBW.Defaults.masterPassword)
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys.union([BWClient.passwordVariable]))
        #expect(
            try fake.lastArguments() == [
                "login", FakeBW.Defaults.email, "--passwordenv", BWClient.passwordVariable, "--nointeraction",
            ])
        try expectNoSecretsInArguments(fake)
    }

    @Test func loginPasswordWithTwoFactorCode() async throws {
        let fake = try FakeBW()
        try fake.configure(["two_factor_code": "123456"])
        let client = fake.client()
        let email = FakeBW.Defaults.email
        let password = FakeBW.Defaults.masterPassword

        await #expect(throws: BWError.twoFactorRequired) {
            try await client.loginPassword(email: email, password: password)
        }
        await #expect(throws: BWError.invalidTwoFactorCode) {
            try await client.loginPassword(
                email: email, password: password, twoFactor: BWTwoFactor(method: .authenticator, code: "000000"))
        }
        try await client.loginPassword(
            email: email, password: password, twoFactor: BWTwoFactor(method: .authenticator, code: "123456"))
        let arguments = try fake.lastArguments()
        #expect(arguments.suffix(5) == ["--method", "0", "--code", "123456", "--nointeraction"])
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys.union([BWClient.passwordVariable]))
        try expectNoSecretsInArguments(fake)
    }

    @Test func loginFailuresAreTyped() async throws {
        let fake = try FakeBW()
        let client = fake.client()
        await #expect(throws: BWError.invalidPassword) {
            try await client.loginPassword(email: FakeBW.Defaults.email, password: "wrong")
        }
        await #expect(throws: BWError.invalidAPIKey) {
            try await client.loginAPIKey(clientID: "wrong", clientSecret: "wrong")
        }
        try fake.configure(["offline": true])
        await #expect(throws: BWError.network) {
            try await client.loginPassword(email: FakeBW.Defaults.email, password: FakeBW.Defaults.masterPassword)
        }
    }

    @Test func unlockReturnsTheSessionKey() async throws {
        let fake = try FakeBW()
        try fake.setState("locked")
        let client = fake.client()
        await #expect(throws: BWError.invalidPassword) { try await client.unlock(password: "wrong") }
        let key = try await client.unlock(password: FakeBW.Defaults.masterPassword)
        #expect(key == FakeBW.session)
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys.union([BWClient.passwordVariable]))
        #expect(
            try fake.lastArguments() == [
                "unlock", "--passwordenv", BWClient.passwordVariable, "--raw", "--nointeraction",
            ])
        try expectNoSecretsInArguments(fake)
    }

    @Test func unlockWhileLoggedOutIsUnauthenticated() async throws {
        let fake = try FakeBW()
        await #expect(throws: BWError.unauthenticated) {
            try await fake.client().unlock(password: FakeBW.Defaults.masterPassword)
        }
    }

    @Test func listsDecodeIntoTheCallersType() async throws {
        let fake = try FakeBW.unlocked()
        let client = fake.client()

        let items: [Named] = try await client.listItems(session: FakeBW.session)
        #expect(items.count == 15)
        #expect(try fake.lastArguments() == ["list", "items", "--nointeraction"])
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys.union(["BW_SESSION"]))
        try expectNoSecretsInArguments(fake)

        let folders: [Named] = try await client.listFolders(session: FakeBW.session)
        #expect(folders.count == 2)
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys.union(["BW_SESSION"]))
        try expectNoSecretsInArguments(fake)

        let organizations: [Named] = try await client.listOrganizations(session: FakeBW.session)
        #expect(organizations.count == 1)
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys.union(["BW_SESSION"]))
        try expectNoSecretsInArguments(fake)
    }

    @Test func rejectedSessionIsLocked() async throws {
        let fake = try FakeBW.unlocked()
        await #expect(throws: BWError.locked) {
            let _: [Named] = try await fake.client().listItems(session: SessionKey("stale-session"))
        }
    }

    @Test func getPasswordReturnsTheExactValue() async throws {
        let fake = try FakeBW.unlocked()
        let password = try await fake.client().getPassword(id: FakeBW.Item.github, session: FakeBW.session)
        #expect(password == FakeBW.Item.githubPassword)
        #expect(try fake.lastArguments() == ["get", "password", FakeBW.Item.github, "--raw", "--nointeraction"])
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys.union(["BW_SESSION"]))
        try expectNoSecretsInArguments(fake)
    }

    @Test func getTOTPReturnsTheCode() async throws {
        let fake = try FakeBW.unlocked()
        let client = fake.client()
        #expect(try await client.getTOTP(id: FakeBW.Item.github, session: FakeBW.session) == FakeBW.Defaults.totpCode)
        #expect(try fake.lastArguments() == ["get", "totp", FakeBW.Item.github, "--raw", "--nointeraction"])
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys.union(["BW_SESSION"]))
        try expectNoSecretsInArguments(fake)
        await #expect(throws: BWError.noValue) {
            try await client.getTOTP(id: FakeBW.Item.gitlab, session: FakeBW.session)
        }
    }

    @Test func getForUnknownItemIsNotFound() async throws {
        let fake = try FakeBW.unlocked()
        await #expect(throws: BWError.itemNotFound) {
            try await fake.client().getPassword(id: UUID().uuidString.lowercased(), session: FakeBW.session)
        }
    }

    @Test func syncPassesTheSessionAndReportsOffline() async throws {
        let fake = try FakeBW.unlocked()
        let client = fake.client()
        try await client.sync(session: FakeBW.session)
        #expect(try fake.lastArguments() == ["sync", "--nointeraction"])
        #expect(try fake.lastEnvironmentKeys() == Self.baseKeys.union(["BW_SESSION"]))
        try expectNoSecretsInArguments(fake)
        try fake.configure(["offline": true])
        await #expect(throws: BWError.network) { try await client.sync(session: FakeBW.session) }
    }

    @Test func lockAndLogout() async throws {
        let fake = try FakeBW.unlocked()
        let client = fake.client()
        try await client.lock()
        #expect(try await client.status(session: FakeBW.session).state == .locked)
        try await client.logout()
        #expect(try await client.status().state == .unauthenticated)
    }

    @Test func configServerChangesTheServer() async throws {
        let fake = try FakeBW()
        let client = fake.client()
        try await client.configServer(#require(URL(string: "https://vault.example.test")))
        #expect(try await client.status().serverURL == "https://vault.example.test")
    }

    @Test func versionIsParsedAndCheckedAgainstTheMinimum() async throws {
        let fake = try FakeBW()
        let client = fake.client()
        #expect(try await client.version() == BWVersion(components: [2026, 9, 0]))
        try fake.configure(["version": "2024.12.1"])
        await #expect(throws: BWError.tooOld(installed: "2024.12.1")) { try await client.version() }
    }

    @Test func versionOrdering() throws {
        #expect(BWVersion("2025.1.0") == BWClient.minimumVersion)
        #expect(BWVersion("2025.1") == BWVersion("2025.1.0"))
        #expect(try #require(BWVersion("2024.12.9")) < BWClient.minimumVersion)
        #expect(BWClient.minimumVersion < (try #require(BWVersion("2025.10.0"))))
        #expect(BWVersion("not a version") == nil)
    }

    // MARK: Argument validation

    /// Values that would read as options (or are not what they claim) are refused before a process starts.
    @Test func unsafeArgumentsNeverStartAProcess() async throws {
        let fake = try FakeBW.unlocked()
        let client = fake.client()
        await #expect(throws: BWError.invalidArgument) {
            try await client.getPassword(id: "--session", session: FakeBW.session)
        }
        await #expect(throws: BWError.invalidArgument) {
            try await client.loginPassword(email: "--apikey", password: "x")
        }
        await #expect(throws: BWError.invalidArgument) {
            try await client.loginPassword(email: "a@b.test\n--raw", password: "x")
        }
        await #expect(throws: BWError.invalidArgument) {
            try await client.loginPassword(
                email: FakeBW.Defaults.email, password: "x", twoFactor: BWTwoFactor(method: .email, code: "-1"))
        }
        for server in [
            "ftp://vault.example.test", "file:///etc", "https://", "https://user:pw@vault.example.test",
            "https://vault.example.test/?token=x", "https://vault.example.test/#x",
        ] {
            await #expect(throws: BWError.invalidArgument) {
                try await client.configServer(#require(URL(string: server)))
            }
        }
        #expect(try fake.calls().isEmpty)
    }
}
