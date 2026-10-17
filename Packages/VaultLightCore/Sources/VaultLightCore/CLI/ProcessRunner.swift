import Foundation

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
        process.terminationHandler = { finished in
            exitContinuation.yield(
                Exit(status: finished.terminationStatus, bySignal: finished.terminationReason == .uncaughtSignal))
            exitContinuation.finish()
        }
        let stdoutChunks = chunks(of: stdoutPipe.fileHandleForReading)
        let stderrChunks = chunks(of: stderrPipe.fileHandleForReading)

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        let pid = process.processIdentifier
        let watchdog = Task<Bool, Never> {
            do { try await Task.sleep(for: timeout) } catch { return false }
            kill(pid, SIGTERM)
            if (try? await Task.sleep(for: killGrace)) != nil { kill(pid, SIGKILL) }
            return true
        }

        async let stdout = collect(stdoutChunks)
        async let stderr = collect(stderrChunks)
        var exit = Exit(status: -1, bySignal: false)
        for await finished in exits { exit = finished }
        watchdog.cancel()

        return ProcessOutput(
            status: exit.status, terminatedBySignal: exit.bySignal, timedOut: await watchdog.value,
            stdout: await stdout, stderr: await stderr)
    }

    /// Reads a pipe without blocking a thread; the stream ends at EOF.
    private static func chunks(of handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
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
    }

    private static func collect(_ chunks: AsyncStream<Data>) async -> Data {
        var data = Data()
        for await chunk in chunks { data.append(chunk) }
        return data
    }
}
