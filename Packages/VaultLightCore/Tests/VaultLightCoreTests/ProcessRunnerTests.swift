import Foundation
import Testing

@testable import VaultLightCore

/// Spec 7.1 "Timeouts": SIGTERM at the timeout, SIGKILL after the grace period.
/// Delays reach the fake through its config file (`delay`), the minimal-environment form of FAKE_BW_DELAY.
@Suite("ProcessRunner")
struct ProcessRunnerTests {
    private func environment(_ fake: FakeBW) -> [String: String] {
        ["HOME": fake.dataDirectory.path, "PATH": "/usr/bin:/bin", "BITWARDENCLI_APPDATA_DIR": fake.dataDirectory.path]
    }

    private func run(
        _ fake: FakeBW, _ arguments: [String], timeout: Duration = .seconds(15), killGrace: Duration = .seconds(2)
    ) async throws -> ProcessOutput {
        try await ProcessRunner.run(
            FakeBW.executable, arguments: arguments, environment: environment(fake), timeout: timeout,
            killGrace: killGrace)
    }

    @Test func capturesStatusAndBothStreams() async throws {
        let fake = try FakeBW()
        let success = try await run(fake, ["status", "--nointeraction"])
        #expect(success.status == 0 && !success.timedOut && !success.terminatedBySignal)
        #expect(String(bytes: success.stdout, encoding: .utf8)?.contains("\"unauthenticated\"") == true)

        let failed = try await run(fake, ["list", "items", "--nointeraction"])
        #expect(failed.status == 1)
        #expect(String(bytes: failed.stderr, encoding: .utf8) == "You are not logged in.\n")
    }

    /// Output larger than a pipe buffer must not deadlock the child.
    @Test func readsOutputLargerThanThePipeBuffer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultlight-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("big")
        let content = Data(repeating: UInt8(ascii: "a"), count: 2_000_000)
        try content.write(to: file)

        let output = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/cat"), arguments: [file.path], environment: [:], timeout: .seconds(15),
            killGrace: .seconds(2))
        #expect(output.status == 0)
        #expect(output.stdout == content)
    }

    @Test func timeoutSendsSIGTERM() async throws {
        let fake = try FakeBW()
        try fake.configure(["delay": ["status": 30]])
        let start = ContinuousClock.now
        let output = try await run(
            fake, ["status", "--nointeraction"], timeout: .milliseconds(500), killGrace: .seconds(10))
        #expect(output.timedOut)
        #expect(output.terminatedBySignal && output.status == SIGTERM)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// The timeout leaves the fake time to install its SIGTERM handler even when many tests start processes at once.
    @Test func escalatesToSIGKILLWhenSIGTERMIsIgnored() async throws {
        let fake = try FakeBW()
        try fake.configure(["delay": ["status": 30], "ignore_sigterm": true])
        let start = ContinuousClock.now
        let output = try await run(
            fake, ["status", "--nointeraction"], timeout: .seconds(2), killGrace: .milliseconds(700))
        let elapsed = ContinuousClock.now - start
        #expect(output.timedOut)
        #expect(output.terminatedBySignal && output.status == SIGKILL)
        #expect(elapsed >= .milliseconds(2700))
        #expect(elapsed < .seconds(15))
    }

    @Test func fastCallIsNotTimedOut() async throws {
        let fake = try FakeBW()
        try fake.configure(["delay": ["status": 0.2]])
        let output = try await run(fake, ["status", "--nointeraction"], timeout: .seconds(5))
        #expect(output.status == 0 && !output.timedOut)
    }

    @Test func missingExecutableThrows() async throws {
        await #expect(throws: (any Error).self) {
            try await ProcessRunner.run(
                URL(fileURLWithPath: "/nonexistent/bw"), arguments: [], environment: [:], timeout: .seconds(1),
                killGrace: .seconds(1))
        }
    }
}
