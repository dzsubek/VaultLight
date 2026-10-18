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

/// Starts one child process (spec 7.1) with `posix_spawn`: the executable path plus an argv array, never a shell and
/// never a PATH lookup; an explicit environment, never the inherited one; stdin from /dev/null so nothing can
/// prompt. It does not use `Process`, because Foundation converts every argument and environment value with
/// `fileSystemRepresentation`, which decomposes Unicode (NFC "ő" arrives as "o" + U+030B) and so changes the bytes
/// of a non-ASCII master password; here each string is passed as its own UTF-8 bytes, with no normalization.
///
/// Only `BWClient` calls this; it is the single place in the app that starts processes.
enum ProcessRunner {
    private struct Exit: Sendable {
        let status: Int32
        let bySignal: Bool
    }

    /// `posix_spawn` or one of its setup calls failed. `BWClient` treats any throw as "bw cannot be started".
    private struct SpawnError: Error {
        let code: Int32
    }

    /// A running child and the read ends of its stdout and stderr pipes.
    private struct Child {
        let pid: pid_t
        let stdoutFD: Int32
        let stderrFD: Int32
    }

    static func run(
        _ executable: URL, arguments: [String], environment: [String: String], timeout: Duration,
        killGrace: Duration
    ) async throws -> ProcessOutput {
        let child = try spawn(executable: executable.path, arguments: arguments, environment: environment)
        let pid = child.pid
        let stdoutReader = PipeReader(FileHandle(fileDescriptor: child.stdoutFD, closeOnDealloc: true))
        let stderrReader = PipeReader(FileHandle(fileDescriptor: child.stderrFD, closeOnDealloc: true))

        // Set when the child has exited, before it is reaped, so the watchdog never signals a reaped PID that
        // another process may have reused: until the reap the zombie keeps the PID, and after the flag is set
        // nothing signals it any more.
        let exited = OSAllocatedUnfairLock(initialState: false)
        let (exits, exitContinuation) = AsyncStream.makeStream(of: Exit.self)
        waitForExit(pid: pid, exited: exited, continuation: exitContinuation)
        let watchdog = startWatchdog(pid: pid, exited: exited, timeout: timeout, killGrace: killGrace)

        async let stdout = stdoutReader.collect()
        async let stderr = stderrReader.collect()
        var exit = Exit(status: -1, bySignal: false)
        for await finished in exits { exit = finished }
        watchdog.cancel()

        let drainDeadline = startDrainDeadline(readers: [stdoutReader, stderrReader], killGrace: killGrace)
        let stdoutData = await stdout
        let stderrData = await stderr
        drainDeadline.cancel()
        // Anything the child started still holds the call's secret in its environment, whether or not it kept the
        // pipes: kill what is left of the group. The group ID can't be reused while a member lives; if it's empty,
        // this fails with ESRCH. A process that left the group is out of reach, but if it holds the pipes the
        // output is marked incomplete and the call fails.
        killpg(pid, SIGKILL)
        return ProcessOutput(
            status: exit.status, terminatedBySignal: exit.bySignal, timedOut: await watchdog.value,
            stdout: stdoutData, stderr: stderrData, outputComplete: stdoutReader.reachedEnd && stderrReader.reachedEnd)
    }

    // MARK: - Spawning

    /// Starts `executable` with exactly `arguments` and `environment`. Only the file actions' descriptors reach the
    /// child (`POSIX_SPAWN_CLOEXEC_DEFAULT`): 0 is /dev/null, 1 and 2 are the write ends of two new pipes. The
    /// child leads its own process group, so the watchdog and the final `killpg` reach everything it starts, and it
    /// starts with an empty signal mask and default dispositions for the usual signals.
    private static func spawn(executable: String, arguments: [String], environment: [String: String]) throws -> Child {
        // The exact UTF-8 bytes of each String, NUL-terminated. A NUL inside a value would silently cut it short.
        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        guard (argv + envp).allSatisfy({ !$0.utf8.contains(0) }) else { throw SpawnError(code: EINVAL) }
        let cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnvironment: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var fileActionsReady = false
        var attributesReady = false
        defer {
            for pointer in cArguments + cEnvironment { free(pointer) }
            if fileActionsReady { posix_spawn_file_actions_destroy(&fileActions) }
            if attributesReady { posix_spawnattr_destroy(&attributes) }
            // The child has its own copies; the parent keeps only the read ends, and only on success (see below).
            for descriptor in [stdoutPipe[1], stderrPipe[1]] where descriptor >= 0 { close(descriptor) }
        }

        func check(_ code: Int32) throws {
            if code != 0 { throw SpawnError(code: code) }
        }
        func failClosing(_ error: any Error) -> any Error {
            for descriptor in [stdoutPipe[0], stderrPipe[0]] where descriptor >= 0 { close(descriptor) }
            return error
        }

        do {
            guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else { throw SpawnError(code: errno) }
            // Close-on-exec in the parent too, so a process started concurrently elsewhere can't inherit them.
            // `dup2` in the child clears the flag on descriptors 1 and 2.
            for descriptor in stdoutPipe + stderrPipe { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }

            try check(posix_spawn_file_actions_init(&fileActions))
            fileActionsReady = true
            try check(posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0))
            try check(posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], 1))
            try check(posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], 2))

            try check(posix_spawnattr_init(&attributes))
            attributesReady = true
            try configure(&attributes)

            var pid: pid_t = 0
            try check(posix_spawn(&pid, executable, &fileActions, &attributes, cArguments, cEnvironment))
            return Child(pid: pid, stdoutFD: stdoutPipe[0], stderrFD: stderrPipe[0])
        } catch {
            throw failClosing(error)
        }
    }

    /// Process group of its own, empty signal mask, default dispositions for the signals a parent may ignore, and
    /// every descriptor not named by a file action closed in the child.
    private static func configure(_ attributes: inout posix_spawnattr_t?) throws {
        var mask = sigset_t()
        var defaults = sigset_t()
        sigemptyset(&mask)
        sigemptyset(&defaults)
        for number in [SIGTERM, SIGINT, SIGPIPE, SIGHUP, SIGQUIT] { sigaddset(&defaults, number) }
        var code = posix_spawnattr_setsigmask(&attributes, &mask)
        if code == 0 { code = posix_spawnattr_setsigdefault(&attributes, &defaults) }
        if code == 0 { code = posix_spawnattr_setpgroup(&attributes, 0) }
        if code == 0 {
            let flags =
                POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_CLOEXEC_DEFAULT
            code = posix_spawnattr_setflags(&attributes, Int16(flags))
        }
        if code != 0 { throw SpawnError(code: code) }
    }

    // MARK: - Exit

    /// Waits for the child on a dedicated thread (a blocking wait must not take a cooperative-pool thread). It first
    /// waits for the exit without reaping (`WNOWAIT`), then sets `exited`, and only then reaps with `waitpid`, so
    /// the PID stays reserved by the zombie for as long as the watchdog may still signal it.
    private static func waitForExit(
        pid: pid_t, exited: OSAllocatedUnfairLock<Bool>, continuation: AsyncStream<Exit>.Continuation
    ) {
        let thread = Thread {
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
            exited.withLock { $0 = true }
            var status: Int32 = 0
            var result = waitpid(pid, &status, 0)
            while result == -1 && errno == EINTR { result = waitpid(pid, &status, 0) }
            if result == pid {
                continuation.yield(Exit(status: exitStatus(status), bySignal: wasSignaled(status)))
            }
            continuation.finish()
        }
        thread.name = "VaultLight.bw-wait"
        thread.start()
    }

    // The wait-status macros (WIFEXITED, ...) aren't imported into Swift.
    private static func wasSignaled(_ status: Int32) -> Bool {
        let code = status & 0x7f
        return code != 0 && code != 0x7f
    }

    /// The exit status, or the signal number when the child was killed by a signal.
    private static func exitStatus(_ status: Int32) -> Int32 {
        wasSignaled(status) ? status & 0x7f : (status >> 8) & 0xff
    }

    /// SIGTERM at the timeout, SIGKILL after the grace period, only while the child hasn't exited. Returns whether
    /// it fired. The child leads its own process group (`spawn` sets that up), so anything it started is signalled too.
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

    /// Started once the child has exited. Something it started may still hold the pipes open; after the grace
    /// period, stop reading, so no call outlives its timeout or stalls the queue. `run` then kills the leftovers.
    private static func startDrainDeadline(readers: [PipeReader], killGrace: Duration) -> Task<Void, Never> {
        Task {
            guard (try? await Task.sleep(for: killGrace)) != nil else { return }
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
