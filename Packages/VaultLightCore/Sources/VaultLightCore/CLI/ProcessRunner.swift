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

        // Set once the child has exited, before anything is reaped. The zombie keeps the PID (and so the process
        // group ID) reserved until `run` reaps it, which happens after the last signal this call sends. The
        // watchdog signals only while the flag is false, and `run` sets it before reaping, so no signal is ever
        // sent to a PID that has been reaped and might have been reused.
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
        // pipes: kill what is left of the group. The child is still an unreaped zombie here, so its PID and
        // process group ID are reserved and this can't hit an unrelated process; if the group is otherwise empty
        // it fails with ESRCH. A process that left the group is out of reach, but if it holds the pipes the
        // output is marked incomplete and the call fails.
        let timedOut = await watchdog.value
        exited.withLock { $0 = true }
        killpg(pid, SIGKILL)
        // Reap last, exactly once. After the SIGKILL above (or the exit seen by the wait thread) this is prompt.
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        return ProcessOutput(
            status: exit.status, terminatedBySignal: exit.bySignal, timedOut: timedOut,
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
        let cArguments = try makeCStrings(argv)
        let cEnvironment: [UnsafeMutablePointer<CChar>?]
        do {
            cEnvironment = try makeCStrings(envp)
        } catch {
            wipeAndFree(cArguments)
            throw error
        }
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var fileActionsReady = false
        var attributesReady = false
        defer {
            wipeAndFree(cArguments)
            wipeAndFree(cEnvironment)
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

    /// NUL-terminated copies of the strings' own UTF-8 bytes, plus the trailing nil `posix_spawn` expects. If any
    /// allocation fails, the copies made so far are wiped and freed and this throws, rather than returning a
    /// shortened array.
    private static func makeCStrings(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        for string in strings {
            guard let copy = strdup(string) else {
                wipeAndFree(pointers)
                throw SpawnError(code: ENOMEM)
            }
            pointers.append(copy)
        }
        return pointers + [nil]
    }

    /// The buffers hold secrets (the master password, session key), so they are zeroed before they are freed.
    private static func wipeAndFree(_ pointers: [UnsafeMutablePointer<CChar>?]) {
        for case let pointer? in pointers {
            let size = strlen(pointer) + 1
            memset_s(pointer, size, 0, size)
            free(pointer)
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

    /// Waits for the child on a dedicated thread (a blocking wait must not take a cooperative-pool thread). It
    /// waits for the exit without reaping (`WNOWAIT`), sets `exited`, and reports how the child ended, from the
    /// `siginfo_t`. The child stays a zombie, and so keeps its PID, until `run` reaps it after its final `killpg`.
    private static func waitForExit(
        pid: pid_t, exited: OSAllocatedUnfairLock<Bool>, continuation: AsyncStream<Exit>.Continuation
    ) {
        let thread = Thread {
            var info = siginfo_t()
            var result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
            while result != 0 && errno == EINTR { result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) }
            exited.withLock { $0 = true }
            if result == 0 {
                // si_status is the exit status for CLD_EXITED and the signal number for CLD_KILLED / CLD_DUMPED.
                let bySignal = info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED
                continuation.yield(Exit(status: info.si_status, bySignal: bySignal))
            }
            continuation.finish()
        }
        thread.name = "VaultLight.bw-wait"
        thread.start()
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
