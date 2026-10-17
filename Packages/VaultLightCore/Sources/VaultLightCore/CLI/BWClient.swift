import Foundation
import os

/// A Bitwarden session key. Its description never contains the value, so it can't leak through
/// string interpolation, `dump` or a debugger summary.
public struct SessionKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { "SessionKey(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// `bw status` output (spec 3.1).
public struct BWStatus: Sendable, Equatable, Decodable {
    public enum State: String, Sendable, Decodable {
        case unauthenticated, locked, unlocked
    }

    public let state: State
    public let serverURL: String?
    public let userEmail: String?

    enum CodingKeys: String, CodingKey {
        case state = "status"
        case serverURL = "serverUrl"
        case userEmail
    }
}

/// A dotted `bw` version such as `2026.9.0`.
public struct BWVersion: Sendable, Comparable, CustomStringConvertible {
    public let components: [Int]

    public init(components: [Int]) { self.components = components }

    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(
            separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !parts.isEmpty, numbers.count == parts.count else { return nil }
        components = numbers
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    /// Missing trailing components count as zero, so 2025.1 == 2025.1.0.
    private func padded(to count: Int) -> [Int] { components + Array(repeating: 0, count: count - components.count) }

    public static func == (lhs: BWVersion, rhs: BWVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count) == rhs.padded(to: count)
    }

    public static func < (lhs: BWVersion, rhs: BWVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count).lexicographicallyPrecedes(rhs.padded(to: count))
    }
}

/// A two-step login code for `bw login --method <m> --code <c>` (spec 7.2). The code is one-time, so it may be an argument.
public struct BWTwoFactor: Sendable {
    public enum Method: Int, Sendable {
        case authenticator = 0
        case email = 1
    }

    public let method: Method
    public let code: String

    public init(method: Method, code: String) {
        self.method = method
        self.code = code
    }
}

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
    private let configuredPath: String?
    private let dataDirectory: URL
    private let home: String
    private let timeouts: Timeouts
    private var queueTail: Task<Void, Never>?

    /// `configuredPath` is the Settings `bw` path (nil for auto-detect). The binary is located and checked again
    /// right before every call, so a swapped binary, a `brew upgrade` or a permission change is seen.
    public init(
        locator: BWLocator = BWLocator(), configuredPath: String? = nil,
        dataDirectory: URL = BWClient.defaultDataDirectory,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path, timeouts: Timeouts = .default
    ) {
        self.locator = locator
        self.configuredPath = configuredPath
        self.dataDirectory = dataDirectory
        self.home = home
        self.timeouts = timeouts
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
            guard !twoFactor.code.isEmpty, twoFactor.code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            else { throw BWError.invalidArgument }
            arguments += ["--method", String(twoFactor.method.rawValue), "--code", twoFactor.code]
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
                return try await ProcessRunner.run(
                    executable.url, arguments: arguments + ["--nointeraction"], environment: environment,
                    timeout: timeout, killGrace: killGrace)
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
        } else if output.status != 0 || output.terminatedBySignal {
            error = BWError.classify(
                stderr: String(bytes: output.stderr, encoding: .utf8) ?? "", exitStatus: output.status,
                secrets: Array(secrets.values))
        } else {
            return output
        }
        Self.logger.error(
            "bw \(arguments.first ?? "", privacy: .private) failed: \(String(describing: error), privacy: .private)")
        throw error
    }
}
