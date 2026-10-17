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
        let watchdog = Task<Bool, Never> {
            do { try await Task.sleep(for: timeout) } catch { return false }
            func signal(_ number: Int32) { exited.withLock { if !$0 { kill(pid, number) } } }
            signal(SIGTERM)
            if (try? await Task.sleep(for: killGrace)) != nil { signal(SIGKILL) }
            return true
        }

        async let stdout = stdoutReader.collect()
        async let stderr = stderrReader.collect()
        var exit = Exit(status: -1, bySignal: false)
        for await finished in exits { exit = finished }
        watchdog.cancel()

        // The child is gone, but something it started may still hold the pipes open. Read what is there for at
        // most the grace period, then stop, so no call outlives its timeout and stalls the queue behind it.
        let drainDeadline = Task {
            guard (try? await Task.sleep(for: killGrace)) != nil else { return }
            stdoutReader.stop()
            stderrReader.stop()
        }
        let output = ProcessOutput(
            status: exit.status, terminatedBySignal: exit.bySignal, timedOut: await watchdog.value,
            stdout: await stdout, stderr: await stderr)
        drainDeadline.cancel()
        return output
    }

    /// Reads a pipe without blocking a thread. The stream ends at EOF, or when `stop()` is called.
    private struct PipeReader: Sendable {
        private let handle: FileHandle
        private let chunks: AsyncStream<Data>
        private let continuation: AsyncStream<Data>.Continuation

        init(_ handle: FileHandle) {
            self.handle = handle
            let (chunks, continuation) = AsyncStream.makeStream(of: Data.self)
            self.chunks = chunks
            self.continuation = continuation
            handle.readabilityHandler = { readable in
                let data = readable.availableData
                if data.isEmpty {
                    readable.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }

        func stop() {
            handle.readabilityHandler = nil
            continuation.finish()
        }

        func collect() async -> Data {
            var data = Data()
            for await chunk in chunks { data.append(chunk) }
            return data
        }
    }
}
