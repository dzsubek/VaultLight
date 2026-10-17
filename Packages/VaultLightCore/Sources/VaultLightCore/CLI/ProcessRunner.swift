import Foundation
import os

/// What a finished child process left behind.
struct ProcessOutput: Sendable {
    /// Exit status, or the signal number when `terminatedBySignal`.
    let status: Int32
    let terminatedBySignal: Bool
    /// The watchdog fired: the child was sent SIGTERM (and SIGKILL if it outlived the grace period).
    let timedOut: Bool
    let stdout: Data
    let stderr: Data
    /// Both pipes reached end-of-file. False when a leftover process held them open and reading was cut off, so
    /// `stdout` may be partial.
    let outputComplete: Bool
}

/// Starts one child process (spec 7.1): `executableURL` plus an argument array, never a shell; an explicit
/// environment, never the inherited one; stdin from /dev/null so nothing can prompt.
///
/// Only `BWClient` calls this; it is the single place in the app that starts processes.
enum ProcessRunner {
    private struct Exit: Sendable {
        let status: Int32
        let bySignal: Bool
    }

    static func run(
        _ executable: URL, arguments: [String], environment: [String: String], timeout: Duration,
        killGrace: Duration
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (exits, exitContinuation) = AsyncStream.makeStream(of: Exit.self)
        // Set on exit so the watchdog never signals a reaped PID that another process may have reused.
        // A tiny window remains: Foundation reaps the child just before it calls the handler.
        let exited = OSAllocatedUnfairLock(initialState: false)
        process.terminationHandler = { finished in
            exited.withLock { $0 = true }
            exitContinuation.yield(
                Exit(status: finished.terminationStatus, bySignal: finished.terminationReason == .uncaughtSignal))
            exitContinuation.finish()
        }
        let stdoutReader = PipeReader(stdoutPipe.fileHandleForReading)
        let stderrReader = PipeReader(stderrPipe.fileHandleForReading)

        do {
            try process.run()
        } catch {
            stdoutReader.stop()
            stderrReader.stop()
            throw error
        }

        let pid = process.processIdentifier
        let watchdog = startWatchdog(pid: pid, exited: exited, timeout: timeout, killGrace: killGrace)

        async let stdout = stdoutReader.collect()
        async let stderr = stderrReader.collect()
        var exit = Exit(status: -1, bySignal: false)
        for await finished in exits { exit = finished }
        watchdog.cancel()

        let drainDeadline = startDrainDeadline(pid: pid, readers: [stdoutReader, stderrReader], killGrace: killGrace)
        let stdoutData = await stdout
        let stderrData = await stderr
        drainDeadline.cancel()
        return ProcessOutput(
            status: exit.status, terminatedBySignal: exit.bySignal, timedOut: await watchdog.value,
            stdout: stdoutData, stderr: stderrData, outputComplete: stdoutReader.reachedEnd && stderrReader.reachedEnd)
    }

    /// SIGTERM at the timeout, SIGKILL after the grace period, only while the child hasn't exited. Returns whether
    /// it fired. The child leads its own process group (Process sets that up), so anything it started is signalled too.
    private static func startWatchdog(
        pid: pid_t, exited: OSAllocatedUnfairLock<Bool>, timeout: Duration, killGrace: Duration
    ) -> Task<Bool, Never> {
        Task {
            do { try await Task.sleep(for: timeout) } catch { return false }
            func signal(_ number: Int32) {
                exited.withLock {
                    guard !$0 else { return }
                    kill(pid, number)
                    killpg(pid, number)
                }
            }
            signal(SIGTERM)
            if (try? await Task.sleep(for: killGrace)) != nil { signal(SIGKILL) }
            return true
        }
    }

    /// Started once the child has exited. Something it started may still hold the pipes open, with the call's
    /// secret in its environment. After the grace period, kill what is left of the child's process group (its ID
    /// can't be reused while a member lives) and stop reading, so no call outlives its timeout or stalls the queue.
    private static func startDrainDeadline(pid: pid_t, readers: [PipeReader], killGrace: Duration) -> Task<Void, Never>
    {
        Task {
            guard (try? await Task.sleep(for: killGrace)) != nil else { return }
            killpg(pid, SIGKILL)
            for reader in readers { reader.stop() }
        }
    }
}

/// Reads a pipe without blocking a thread. The stream ends at EOF, or when `stop()` is called.
private struct PipeReader: Sendable {
    private enum State {
        case reading, ended, stopped
    }

    private let handle: FileHandle
    private let chunks: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State.reading)

    init(_ handle: FileHandle) {
        self.handle = handle
        let (chunks, continuation) = AsyncStream.makeStream(of: Data.self)
        self.chunks = chunks
        self.continuation = continuation
        let state = state
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                readable.readabilityHandler = nil
                state.withLock { if $0 == .reading { $0 = .ended } }
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
    }

    /// True only if EOF came before any `stop()`: a stop wins, because chunks after it are dropped.
    var reachedEnd: Bool { state.withLock { $0 == .ended } }

    func stop() {
        state.withLock { if $0 == .reading { $0 = .stopped } }
        handle.readabilityHandler = nil
        continuation.finish()
    }

    func collect() async -> Data {
        var data = Data()
        for await chunk in chunks { data.append(chunk) }
        return data
    }
}
