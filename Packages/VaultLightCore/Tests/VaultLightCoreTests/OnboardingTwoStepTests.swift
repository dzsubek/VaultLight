import Foundation
import Testing

@testable import VaultLightCore

/// The two-step step (design 11 state 2): the held master password and when it is dropped.
extension OnboardingModelTests {
    @Test func twoStepLoginWithTheAuthenticatorApp() async throws {
        try fake.configure(["two_factor_code": "123456"])
        try await atSignIn()
        await model.signIn(password: FakeBW.Defaults.masterPassword)
        #expect(model.step == .twoFactor)
        #expect(model.twoFactorMethod == .authenticator)
        #expect(model.failure == nil)

        await model.verify(code: "000000")
        #expect(model.step == .twoFactor)
        #expect(model.failure == .wrongCode)
        #expect(model.failure?.message == "That code didn’t work. Enter the current code from your app.")

        await model.verify(code: "123456")
        #expect(model.step == .unlock)
        #expect(try logins().last?.suffix(5) == ["--method", "0", "--code", "123456", "--nointeraction"])
    }

    @Test func twoStepLoginWithAnEmailCode() async throws {
        try fake.configure(["two_factor_code": "654321"])
        try await atSignIn()
        await model.signIn(password: FakeBW.Defaults.masterPassword)
        await model.sendCodeByEmail()
        #expect(model.step == .twoFactor)
        #expect(model.twoFactorMethod == .email)
        #expect(model.emailCodeSent)
        #expect(try logins().last?.suffix(3) == ["--method", "1", "--nointeraction"])

        await model.verify(code: "111111")
        #expect(model.failure == .wrongEmailCode)
        await model.verify(code: "654321")
        #expect(model.step == .unlock)
        #expect(try logins().last?.suffix(5) == ["--method", "1", "--code", "654321", "--nointeraction"])
    }

    @Test func aCodeThatIsNotSixDigitsNeverReachesBW() async throws {
        try fake.configure(["two_factor_code": "123456"])
        try await atSignIn()
        await model.signIn(password: FakeBW.Defaults.masterPassword)
        let before = try fake.calls().count
        await model.verify(code: "12 34")
        await model.verify(code: "-12345")
        #expect(model.failure == .wrongCode)
        #expect(try fake.calls().count == before)
    }

    @Test func closingDuringTwoStepLoginDropsThePassword() async throws {
        try fake.configure(["two_factor_code": "123456"])
        try await atSignIn()
        await model.signIn(password: FakeBW.Defaults.masterPassword)
        #expect(model.holdsPassword)
        model.panelDidClose()
        #expect(!model.holdsPassword)
        #expect(model.step == .signIn)
        #expect(model.email == FakeBW.Defaults.email)
        let before = try fake.calls().count
        await model.verify(code: "123456")
        #expect(try fake.calls().count == before)
    }

    @Test func closingWhileTheFirstLoginRunsNeverHoldsThePassword() async throws {
        try fake.configure(["two_factor_code": "123456", "delay": ["login": 1]])
        try await atSignIn()
        let signIn = Task { await model.signIn(password: FakeBW.Defaults.masterPassword) }
        while !model.isBusy { await Task.yield() }
        model.panelDidClose()
        await signIn.value
        #expect(!model.holdsPassword)
        #expect(model.step == .signIn)
    }

    @Test func droppingHeldSecretsLeavesTheTwoStepStep() async throws {
        try fake.configure(["two_factor_code": "123456"])
        try await atSignIn()
        await model.signIn(password: FakeBW.Defaults.masterPassword)
        #expect(model.holdsPassword)
        model.dropHeldSecrets()
        #expect(!model.holdsPassword)
        #expect(model.step == .signIn)
    }

    @Test func heldPasswordExpiresAfterFiveMinutes() async throws {
        try fake.configure(["two_factor_code": "123456"])
        let waits = DurationRecorder()
        let model = OnboardingModel(
            backend: CLIOnboardingBackend(client: fake.client(), session: session), sleep: { waits.append($0) })
        model.serverOption = .bitwardenUS
        await model.continueFromServer()
        model.email = FakeBW.Defaults.email
        await model.signIn(password: FakeBW.Defaults.masterPassword)
        await model.waitForPasswordExpiry()
        #expect(waits.values == [.seconds(5 * 60)])
        #expect(!model.holdsPassword)
        #expect(model.step == .signIn)
        #expect(model.failure == .twoFactorExpired)
        #expect(model.email == FakeBW.Defaults.email)
    }

    @Test func anAcceptedCodeStopsTheExpiry() async throws {
        try fake.configure(["two_factor_code": "123456"])
        try await atSignIn()
        await model.signIn(password: FakeBW.Defaults.masterPassword)
        #expect(model.isPasswordExpiryPending)
        await model.verify(code: "123456")
        #expect(!model.isPasswordExpiryPending)
        #expect(model.step == .unlock)
    }

    @Test func droppingTheHeldPasswordStopsTheExpiry() async throws {
        try fake.configure(["two_factor_code": "123456"])
        try await atSignIn()
        await model.signIn(password: FakeBW.Defaults.masterPassword)
        model.panelDidClose()
        #expect(!model.isPasswordExpiryPending)
    }

    @Test func backFromTwoStepLoginDropsThePassword() async throws {
        try fake.configure(["two_factor_code": "123456"])
        try await atSignIn()
        await model.signIn(password: FakeBW.Defaults.masterPassword)
        await model.back()
        #expect(model.step == .signIn)
        #expect(!model.holdsPassword)
    }
}
