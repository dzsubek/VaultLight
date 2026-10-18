import Foundation
import os

/// The only way VaultLight runs `bw` (spec 7.1, 7.2).
///
/// - Calls run one at a time, in the order they were made. Actor isolation alone doesn't give that, because an actor
///   is reentrant across `await`, so calls are chained through `queueTail`.
/// - Every call appends `--nointeraction`, gets an explicit minimal environment, and passes secrets only there.
/// - Calls time out (15 s, 60 s for sync), with SIGTERM and then SIGKILL.
public actor BWClient {
    public struct Timeouts: Sendable, Equatable {
        public var standard: Duration
        public var sync: Duration
        /// Time between SIGTERM and SIGKILL.
        public var killGrace: Duration

        public init(standard: Duration, sync: Duration, killGrace: Duration) {
            self.standard = standard
            self.sync = sync
            self.killGrace = killGrace
        }

        public static let `default` = Timeouts(standard: .seconds(15), sync: .seconds(60), killGrace: .seconds(2))
    }

    /// Lowest `bw` version VaultLight accepts. Placeholder until spec 12 settles the tested minimum.
    public static let minimumVersion = BWVersion(components: [2025, 1, 0])

    /// `BITWARDENCLI_APPDATA_DIR`: VaultLight's own CLI state, separate from `bw` in Terminal (spec 7.1).
    public static var defaultDataDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "VaultLight/bw", directoryHint: .isDirectory)
    }

    /// Environment variable that carries the master password to `--passwordenv`.
    static let passwordVariable = "VAULTLIGHT_MASTER_PASSWORD"

    private static let logger = Logger(subsystem: "com.vaultlight.core", category: "bw")

    private let locator: BWLocator
    private var configuredPath: String?
    private let dataDirectory: URL
    private let home: String
    private let timeouts: Timeouts
    private var queueTail: Task<Void, Never>?
    /// The version that passed `checkVersion()`, for this path; checked again after a failure or a path change.
    private var checkedVersion: BWVersion?
    /// A version that passed in an earlier launch, for the same binary; `nil` checks on every launch.
    private let versionMemory: BWVersionMemory?

    /// `configuredPath` is the Settings `bw` path (nil for auto-detect). The binary is located and checked again
    /// right before every call, so a swapped binary, a `brew upgrade` or a permission change is seen.
    public init(
        locator: BWLocator = BWLocator(), configuredPath: String? = nil,
        dataDirectory: URL = BWClient.defaultDataDirectory,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path, timeouts: Timeouts = .default,
        versionMemory: BWVersionMemory? = nil
    ) {
        self.versionMemory = versionMemory
        self.locator = locator
        self.configuredPath = configuredPath
        self.dataDirectory = dataDirectory
        self.home = home
        self.timeouts = timeouts
    }

    /// Changes the Settings `bw` path (`nil` auto-detects). Calls already queued keep the path they started with.
    public func setConfiguredPath(_ path: String?) {
        configuredPath = path
        checkedVersion = nil
    }

    /// `version()` once per path, so a too-old `bw` is reported (spec 7.4) the first time `bw` is needed without
    /// costing a process on every open; with `versionMemory`, once per binary across launches. Returns the installed
    /// version.
    @discardableResult
    public func checkVersion() async throws -> BWVersion {
        if let checkedVersion { return checkedVersion }
        let binary = try executable().url
        if let remembered = versionMemory?.version(for: binary) {
            checkedVersion = remembered
            return remembered
        }
        let before = BWVersionMemory.Fingerprint(of: binary)
        let version = try await version()
        checkedVersion = version
        versionMemory?.remember(version, for: binary, before: before)
        return version
    }

    /// The `bw` the next call would run, after the spec 7.1 checks. Starts no process.
    ///
    /// - Throws: `BWError.notInstalled` or `BWError.unsafeBinary`.
    public func executable() throws -> BWExecutable {
        try locator.locate(configuredPath: configuredPath)
    }

    // MARK: Commands

    /// `bw status`. Pass the session to learn whether it still unlocks the vault.
    public func status(session: SessionKey? = nil) async throws -> BWStatus {
        let output = try await run(["status"], secrets: Self.sessionEnvironment(session))
        return try Self.decode(BWStatus.self, from: output.stdout)
    }

    /// `bw config server <url>`. Only http(s) URLs with a host and no credentials, query or fragment, so nothing
    /// secret reaches argv. Only works while logged out.
    public func configServer(_ url: URL) async throws {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
            let host = url.host(), !host.isEmpty, url.user == nil, url.password == nil, url.query == nil,
            url.fragment == nil
        else { throw BWError.invalidArgument }
        try await run(["config", "server", url.absoluteString])
    }

    /// `bw login --apikey`, with the key in `BW_CLIENTID` / `BW_CLIENTSECRET`. Leaves the vault locked.
    public func loginAPIKey(clientID: String, clientSecret: String) async throws {
        try await run(["login", "--apikey"], secrets: ["BW_CLIENTID": clientID, "BW_CLIENTSECRET": clientSecret])
    }

    /// `bw login <email> --passwordenv`, plus `--method`/`--code` for two-step login.
    ///
    /// The session key `bw` prints is dropped: onboarding unlocks separately (spec 3.2 step 3).
    public func loginPassword(email: String, password: String, twoFactor: BWTwoFactor? = nil) async throws {
        guard Self.isPlainArgument(email), email.contains("@"), !email.contains(where: \.isWhitespace) else {
            throw BWError.invalidArgument
        }
        var arguments = ["login", email, "--passwordenv", Self.passwordVariable]
        if let twoFactor {
            arguments += ["--method", String(twoFactor.method.rawValue)]
            if let code = twoFactor.code {
                guard !code.isEmpty, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                    throw BWError.invalidArgument
                }
                arguments += ["--code", code]
            }
        }
        try await run(arguments, secrets: [Self.passwordVariable: password])
    }

    /// `bw unlock --passwordenv --raw`. Returns the session key.
    public func unlock(password: String) async throws -> SessionKey {
        let output = try await run(
            ["unlock", "--passwordenv", Self.passwordVariable, "--raw"], secrets: [Self.passwordVariable: password])
        let key = try Self.text(output.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
            throw BWError.unknown("bw unlock returned no session key")
        }
        return SessionKey(key)
    }

    /// `bw list items`, decoded straight into `Item`, so the raw JSON (the whole decrypted vault, spec 9.3)
    /// never leaves this call. `Item` should decode metadata only (spec 9.1).
    public func listItems<Item: Decodable & Sendable>(session: SessionKey) async throws -> [Item] {
        try await list("items", session: session)
    }

    /// `bw list folders`.
    public func listFolders<Folder: Decodable & Sendable>(session: SessionKey) async throws -> [Folder] {
        try await list("folders", session: session)
    }

    /// `bw list organizations`.
    public func listOrganizations<Organization: Decodable & Sendable>(session: SessionKey) async throws
        -> [Organization]
    {
        try await list("organizations", session: session)
    }

    /// `bw get password <id> --raw`. The value is returned as is, except a trailing line break.
    public func getPassword(id: String, session: SessionKey) async throws -> String {
        var password = try await get("password", id: id, session: session)
        if password.hasSuffix("\n") { password.removeLast() }
        guard !password.isEmpty else { throw BWError.noValue }
        return password
    }

    /// `bw get totp <id> --raw`. Returns the current code.
    public func getTOTP(id: String, session: SessionKey) async throws -> String {
        let code = try await get("totp", id: id, session: session).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw BWError.noValue }
        return code
    }

    /// `bw sync`, with the longer sync timeout.
    public func sync(session: SessionKey) async throws {
        try await run(["sync"], secrets: Self.sessionEnvironment(session), timeout: timeouts.sync)
    }

    /// `bw lock`.
    public func lock() async throws {
        try await run(["lock"])
    }

    /// `bw logout`.
    public func logout() async throws {
        try await run(["logout"])
    }

    /// `bw --version`. Throws `BWError.tooOld` below `minimumVersion`.
    public func version() async throws -> BWVersion {
        let output = try await run(["--version"])
        let text = try Self.text(output.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = BWVersion(text) else { throw BWError.unknown("Unexpected output from bw --version") }
        guard version >= Self.minimumVersion else { throw BWError.tooOld(installed: version.description) }
        return version
    }

    // MARK: Plumbing

    /// HOME, PATH, BITWARDENCLI_APPDATA_DIR and the call's secrets: nothing inherited (spec 7.1).
    static func environment(
        searchPath: String, home: String, dataDirectory: URL, secrets: [String: String]
    ) -> [String: String] {
        let base = ["HOME": home, "PATH": searchPath, "BITWARDENCLI_APPDATA_DIR": dataDirectory.path]
        return base.merging(secrets) { baseValue, _ in baseValue }
    }

    private static func sessionEnvironment(_ session: SessionKey?) -> [String: String] {
        session.map { ["BW_SESSION": $0.rawValue] } ?? [:]
    }

    /// Not empty, not an option, no control characters: safe as a positional argument.
    private static func isPlainArgument(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-")
            && !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    private static func text(_ data: Data) throws -> String {
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw BWError.unknown("Unexpected output from bw")
        }
        return text
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Clear text: only the decoding failure's kind and coding path (this code's keys and array indices),
            // never a value from the output.
            logger.error(
                "Decoding bw output failed: \(decodingFailure(error), privacy: .public), \(data.count, privacy: .public) bytes"
            )
            throw BWError.unknown("Unexpected output from bw")
        }
    }

    private func list<T: Decodable & Sendable>(_ object: String, session: SessionKey) async throws -> [T] {
        let output = try await run(["list", object], secrets: Self.sessionEnvironment(session))
        return try Self.decode([T].self, from: output.stdout)
    }

    private func get(_ field: String, id: String, session: SessionKey) async throws -> String {
        guard UUID(uuidString: id) != nil else { throw BWError.invalidArgument }
        let output = try await run(["get", field, id, "--raw"], secrets: Self.sessionEnvironment(session))
        return try Self.text(output.stdout)
    }

    /// Runs one `bw` call after every earlier call has finished, and maps failures to `BWError`.
    @discardableResult
    private func run(_ arguments: [String], secrets: [String: String] = [:], timeout: Duration? = nil)
        async throws -> ProcessOutput
    {
        let locator = locator
        let configuredPath = configuredPath
        let dataDirectory = dataDirectory
        let home = home
        let killGrace = timeouts.killGrace
        let timeout = timeout ?? timeouts.standard

        let previous = queueTail
        let call = Task { () async throws -> ProcessOutput in
            await previous?.value
            let executable = try locator.locate(configuredPath: configuredPath)
            try Self.preparePrivateDirectory(dataDirectory)
            let environment = Self.environment(
                searchPath: executable.searchPath, home: home, dataDirectory: dataDirectory, secrets: secrets)
            do {
                let started = ContinuousClock.now
                let output = try await ProcessRunner.run(
                    executable.url, arguments: arguments + ["--nointeraction"], environment: environment,
                    timeout: timeout, killGrace: killGrace)
                // For the spec 10 measurements: the verb from the fixed list and a duration only.
                let elapsed = ContinuousClock.now - started
                let milliseconds =
                    elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
                Self.logger.info(
                    "bw \(Self.verb(of: arguments), privacy: .public) took \(milliseconds, privacy: .public) ms")
                return output
            } catch {
                // ProcessRunner throws only when the launch fails: the binary vanished or can't be executed.
                throw BWError.notInstalled
            }
        }
        queueTail = Task { _ = await call.result }

        let output = try await call.value
        let error: BWError
        if output.timedOut {
            error = .timeout
        } else if !output.outputComplete {
            error = .unknown("bw output was incomplete")
        } else if output.status != 0 || output.terminatedBySignal {
            error = BWError.classify(
                stderr: String(bytes: output.stderr, encoding: .utf8) ?? "", exitStatus: output.status,
                secrets: Array(secrets.values))
        } else {
            return output
        }
        // Clear text: the command verb comes from this file, and the rest are a case name, numbers and flags.
        Self.logger.error(
            """
            bw \(Self.verb(of: arguments), privacy: .public) failed: \(error.diagnosticKind, privacy: .public) \
            (exit \(output.status, privacy: .public), signal \(output.terminatedBySignal, privacy: .public), \
            timed out \(output.timedOut, privacy: .public), output complete \(output.outputComplete, privacy: .public))
            """)
        Self.logger.error("bw failure detail: \(String(describing: error), privacy: .private)")
        throw error
    }
}

extension BWClient {
    /// `kind at path` for a `DecodingError`, with no values from the decoded data.
    static func decodingFailure(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return diagnosticKind(of: error) }
        let (kind, context): (String, DecodingError.Context)
        switch error {
        case .typeMismatch(_, let ctx): (kind, context) = ("typeMismatch", ctx)
        case .valueNotFound(_, let ctx): (kind, context) = ("valueNotFound", ctx)
        case .keyNotFound(let key, let ctx): (kind, context) = ("keyNotFound(\(key.stringValue))", ctx)
        case .dataCorrupted(let ctx): (kind, context) = ("dataCorrupted", ctx)
        @unknown default: return "unknownDecodingError"
        }
        let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        return "\(kind) at \(path.isEmpty ? "top level" : path)"
    }

    /// The command verb for logs, from a fixed list so nothing else from `arguments` can reach clear text.
    private static func verb(of arguments: [String]) -> String {
        let verbs: Set = ["--version", "status", "config", "login", "unlock", "list", "get", "sync", "lock", "logout"]
        guard let first = arguments.first, verbs.contains(first) else { return "other" }
        if first == "list" || first == "get", arguments.count > 1,
            ["items", "folders", "organizations", "password", "totp"].contains(arguments[1])
        {
            return "\(first) \(arguments[1])"
        }
        return first
    }
}

extension BWClient {
    /// Creates the CLI data folder as 0700, or tightens an existing one; refuses one owned by someone else.
    /// It holds the CLI's encrypted vault and keys (spec 7.1 "Isolated CLI state").
    private static func preparePrivateDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attributes = try manager.attributesOfItem(atPath: directory.path)
            guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw BWError.unknown("The bw data folder belongs to another user")
            }
            if (attributes[.posixPermissions] as? NSNumber)?.intValue != 0o700 {
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
        } catch let error as BWError {
            throw error
        } catch {
            throw BWError.unknown("Can't prepare the bw data folder")
        }
    }
}
