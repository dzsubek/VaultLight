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
        #expect(success.status == 0 && !success.timedOut && !success.terminatedBySignal && success.outputComplete)
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
        #expect(output.status == 0 && output.outputComplete)
        #expect(output.stdout == content)
    }

    /// Only 0, 1 and 2 reach the child, even when the parent holds another descriptor open without close-on-exec.
    @Test func childInheritsOnlyStdinStdoutAndStderr() async throws {
        var leaked = [Int32](repeating: -1, count: 2)
        #expect(pipe(&leaked) == 0)
        defer { leaked.forEach { close($0) } }
        let script = "import os\nfor fd in range(3, 64):\n try:\n  os.fstat(fd); print(fd)\n except OSError: pass"
        let output = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script], environment: [:],
            timeout: .seconds(30), killGrace: .seconds(2))
        #expect(output.status == 0 && output.outputComplete)
        #expect(String(bytes: output.stdout, encoding: .utf8) == "")
    }

    /// Arguments, like environment values, reach the child scalar for scalar, precomposed or decomposed.
    @Test(arguments: [
        "t\u{00E9}ster-\u{0151}@example.com",  // precomposed (NFC)
        "te\u{0301}ster-o\u{030B}@example.com",  // decomposed (NFD)
    ])
    func nonASCIIArgumentReachesTheChildUnchanged(argument: String) async throws {
        let fake = try FakeBW()
        _ = try await run(fake, ["status", argument, "--nointeraction"])
        let received = try fake.lastArguments()
        #expect(received.count == 3)
        #expect(Array(received[1].unicodeScalars) == Array(argument.unicodeScalars))
    }

    @Test func failedSpawnThrows() async throws {
        await #expect(throws: (any Error).self) {
            try await ProcessRunner.run(
                URL(fileURLWithPath: "/nonexistent/bw"), arguments: [], environment: [:], timeout: .seconds(5),
                killGrace: .seconds(1))
        }
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

    /// A process the child leaves behind can keep the pipes open, with the call's secret in its environment.
    /// Once the child has exited, the runner reads for at most the kill grace period, then kills the child's
    /// process group and reports the output as incomplete. A call can't outlive its timeout or stall the queue.
    @Test func killsLeftoversThatHoldThePipesAndFlagsTheOutput() async throws {
        let fake = try FakeBW()
        try fake.configure(["orphan_holds_pipes": 45])
        let start = ContinuousClock.now
        let output = try await run(fake, ["--version", "--nointeraction"], killGrace: .seconds(1))
        #expect(ContinuousClock.now - start < .seconds(40))
        #expect(output.status == 0 && !output.timedOut)
        #expect(!output.outputComplete)

        try await expectOrphanGone(fake)
    }

    /// A leftover that let go of the pipes still holds the call's secret in its environment, so it is killed too.
    @Test func killsLeftoversThatClosedThePipes() async throws {
        let fake = try FakeBW()
        try fake.configure(["orphan_detached": 45])
        let output = try await run(fake, ["--version", "--nointeraction"], killGrace: .seconds(1))
        #expect(output.status == 0 && output.outputComplete)
        try await expectOrphanGone(fake)
    }

    private func expectOrphanGone(_ fake: FakeBW) async throws {
        let pidText = try String(
            contentsOf: fake.dataDirectory.appendingPathComponent("fake-orphan-pid"), encoding: .utf8)
        let orphan = try #require(pid_t(pidText))
        var alive = true
        for _ in 0..<50 where alive {
            alive = kill(orphan, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(!alive, "the leftover process is still running")
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
