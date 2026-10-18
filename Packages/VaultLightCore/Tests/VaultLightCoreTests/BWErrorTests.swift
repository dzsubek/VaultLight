import Foundation
import Testing

@testable import VaultLightCore

/// Spec 7.4: failures are typed; unknown output never carries secrets or email addresses.
@Suite("BWError")
struct BWErrorTests {
    @Test(arguments: [
        ("You are not logged in.", BWError.unauthenticated),
        ("Vault is locked.", .locked),
        ("Invalid master password.", .invalidPassword),
        ("Username or password is incorrect. Try again.", .invalidPassword),
        ("client_id or client_secret is incorrect. Try again.", .invalidAPIKey),
        ("Login failed: two-step login code is required.", .twoFactorRequired),
        ("Code is required.", .twoFactorRequired),
        ("Two-step token is invalid. Try again.", .invalidTwoFactorCode),
        ("FetchError: request to https://api.bitwarden.com failed, reason: getaddrinfo ENOTFOUND", .network),
        ("request to https://vault.example.test failed, reason: connect ECONNREFUSED 10.0.0.1:443", .network),
        ("Not found.", .itemNotFound),
        ("No password available for this login.", .noValue),
        ("No TOTP available for this login.", .noValue),
    ])
    func classifiesKnownMessages(stderr: String, expected: BWError) {
        #expect(BWError.classify(stderr: stderr, exitStatus: 1, secrets: []) == expected)
    }

    @Test func stripsColourCodesBeforeMatching() {
        let colored = "\u{1B}[91mVault is locked.\u{1B}[39m\n"
        #expect(BWError.classify(stderr: colored, exitStatus: 1, secrets: []) == .locked)
    }

    @Test func unknownMasksSecretsAndEmails() {
        let stderr = "You are already logged in as tester@example.com with key sekrit-123.\nsecond line sekrit-123"
        let error = BWError.classify(stderr: stderr, exitStatus: 1, secrets: ["sekrit-123"])
        #expect(error == .unknown("You are already logged in as [email] with key [redacted]."))
    }

    @Test func unknownIsCapped() {
        let error = BWError.classify(stderr: String(repeating: "x", count: 1000), exitStatus: 1, secrets: [])
        guard case .unknown(let message) = error else {
            Issue.record("expected unknown, got \(error)")
            return
        }
        #expect(message.count == 200)
    }

    @Test func emptyStderrReportsTheExitStatus() {
        #expect(BWError.classify(stderr: "\n", exitStatus: 99, secrets: []) == .unknown("bw exited with status 99"))
    }

    /// Logs may show the kind of a failure in clear text, so it must never carry a payload.
    @Test func diagnosticKindNamesTheCaseWithoutItsPayload() {
        #expect(BWError.unknown("secret@example.test hunter2").diagnosticKind == "unknown")
        #expect(BWError.tooOld(installed: "2024.1.0").diagnosticKind == "tooOld")
        #expect(BWError.timeout.diagnosticKind == "timeout")
        #expect(diagnosticKind(of: SessionStoreError.cancelled) == "SessionStoreError")
        #expect(diagnosticKind(of: BWError.network) == "network")
    }

    @Test func decodingFailureNamesThePathButNoValues() throws {
        struct Item: Decodable { let name: String }
        let data = Data(#"[{"name": "Bank"}, {"name": 42, "note": "hunter2"}]"#.utf8)
        let error = try #require(throws: DecodingError.self) { try JSONDecoder().decode([Item].self, from: data) }
        let text = BWClient.decodingFailure(error)
        #expect(text == "typeMismatch at [1].name")
        #expect(!text.contains("hunter2") && !text.contains("42"))
    }
}
