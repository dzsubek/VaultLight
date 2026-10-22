import Foundation
import Testing

@testable import VaultLightCore

/// Two-step login through `bw login --method/--code` (spec 7.2).
extension BWClientTests {
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
        #expect(try fake.lastEnvironmentKeys() == Self.passwordKeys)
        try expectNoSecretsInArguments(fake)
    }

    /// The server replaces the emailed code whenever it answers "two-step required", so a login without the code
    /// in between stops the code working; the fake models that.
    @Test func anEmailCodeStopsWorkingAfterALoginWithoutIt() async throws {
        let fake = try FakeBW()
        try fake.configure(["two_factor_code": "482913", "two_factor_providers": [0, 1]])
        let client = fake.client()
        let email = FakeBW.Defaults.email
        let password = FakeBW.Defaults.masterPassword
        let sendEmail = BWTwoFactor(method: .email, code: nil)
        let code = BWTwoFactor(method: .email, code: "482913")

        await #expect(throws: BWError.twoFactorRequired) {
            try await client.loginPassword(email: email, password: password, twoFactor: sendEmail)
        }
        await #expect(throws: BWError.twoFactorMethodRequired) {
            try await client.loginPassword(email: email, password: password)
        }
        await #expect(throws: BWError.invalidTwoFactorCode) {
            try await client.loginPassword(email: email, password: password, twoFactor: code)
        }
        await #expect(throws: BWError.twoFactorRequired) {
            try await client.loginPassword(email: email, password: password, twoFactor: sendEmail)
        }
        try await client.loginPassword(email: email, password: password, twoFactor: code)
        #expect(try fake.twoFactorEmails() == 2)
    }
}
