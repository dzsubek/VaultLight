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
        _ fake: FakeBW, _ arguments: [String], timeout: Duration = .seconds(120), killGrace: Duration = .seconds(2)
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
            URL(fileURLWithPath: "/bin/cat"), arguments: [file.path], environment: [:], timeout: .seconds(120),
            killGrace: .seconds(2))
        #expect(output.status == 0)
        #expect(output.stdout == content)
    }

    /// SIGTERM alone ends it: the status would be SIGKILL if escalation had been needed. The call returns within
    /// timeout + grace for draining, long before the fake's 30 s sleep would end.
    @Test func timeoutSendsSIGTERM() async throws {
        let fake = try FakeBW()
        try fake.configure(["delay": ["status": 30]])
        let start = ContinuousClock.now
        let output = try await run(
            fake, ["status", "--nointeraction"], timeout: .milliseconds(500), killGrace: .seconds(3))
        #expect(output.timedOut)
        #expect(output.terminatedBySignal && output.status == SIGTERM)
        #expect(ContinuousClock.now - start < .seconds(20))
    }

    /// The timeout leaves the fake time to install its SIGTERM handler even when many tests start processes at once.
    ///
    /// The fake logs its call only after it ignores SIGTERM. A run where SIGTERM arrived before that (the fake was
    /// still starting) says nothing about escalation, so it is repeated with a longer timeout.
    @Test func escalatesToSIGKILLWhenSIGTERMIsIgnored() async throws {
        var timeout = Duration.seconds(2)
        for _ in 0..<5 {
            let fake = try FakeBW()
            try fake.configure(["delay": ["status": 300], "ignore_sigterm": true])
            let start = ContinuousClock.now
            let output = try await run(
                fake, ["status", "--nointeraction"], timeout: timeout, killGrace: .milliseconds(700))
            let elapsed = ContinuousClock.now - start
            #expect(output.timedOut && output.terminatedBySignal)
            guard try !fake.calls().isEmpty else {
                #expect(output.status == SIGTERM)
                timeout *= 2
                continue
            }
            #expect(output.status == SIGKILL)
            #expect(elapsed >= timeout + .milliseconds(700))
            return
        }
        Issue.record("the fake never started within the timeout")
    }

    /// A process the child leaves behind can keep the pipes open. Once the child has exited, the runner reads for
    /// at most the kill grace period, so a call can't outlive its timeout and stall the queue.
    @Test func returnsWhenTheChildExitsEvenIfAGrandchildHoldsThePipes() async throws {
        let fake = try FakeBW()
        try fake.configure(["orphan_holds_pipes": 45])
        let start = ContinuousClock.now
        let output = try await run(fake, ["--version", "--nointeraction"], killGrace: .seconds(1))
        #expect(output.status == 0 && !output.timedOut)
        #expect(String(bytes: output.stdout, encoding: .utf8) == FakeBW.Defaults.version + "\n")
        #expect(ContinuousClock.now - start < .seconds(40))
    }

    @Test func fastCallIsNotTimedOut() async throws {
        let fake = try FakeBW()
        try fake.configure(["delay": ["status": 0.2]])
        let output = try await run(fake, ["status", "--nointeraction"])
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
