import Foundation

@testable import VaultLightCore

/// Locates and configures the fake `bw` CLI in `Tests/Fixtures/bw-fake`.
///
/// Each test gets its own data directory (the fake keeps state, config and a call log there),
/// so tests can run in parallel without sharing state. The directory is removed on deinit.
final class FakeBW {
    /// Repository root, derived from this file's location:
    /// <root>/Packages/VaultLightCore/Tests/VaultLightCoreTests/FakeBW.swift
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // VaultLightCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // VaultLightCore
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // <root>

    static let executable: URL = repositoryRoot.appendingPathComponent("Tests/Fixtures/bw-fake/bw")

    /// Finds only the fake. The child PATH starts with `pythonDirectory` instead of a Homebrew bin, so the fake's
    /// `python3` is the interpreter itself.
    static let locator = BWLocator(candidates: [executable.path], homebrewBinDirectories: [pythonDirectory.path])

    /// A private folder whose `python3` links to the interpreter behind macOS's `/usr/bin/python3` shim, resolved
    /// once per test run. Put first on a child's PATH, it lets `#!/usr/bin/env python3` skip the shim, which runs
    /// `xcrun` on every launch: on a loaded CI runner every shim launch stalled for up to two minutes at once
    /// (runs 39163810488, 39754731988), timing out each test that started the fake.
    static let pythonDirectory: URL = {
        let resolve = Process()
        resolve.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        resolve.arguments = ["-f", "python3"]
        let output = Pipe()
        resolve.standardOutput = output
        do { try resolve.run() } catch { preconditionFailure("xcrun -f python3 failed to start: \(error)") }
        let path =
            String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        resolve.waitUntilExit()
        precondition(resolve.terminationStatus == 0 && path.hasPrefix("/"), "xcrun -f python3 found no python3")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultlight-fake-python-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createSymbolicLink(
                atPath: directory.appendingPathComponent("python3").path, withDestinationPath: path)
        } catch {
            preconditionFailure("could not link python3 for the fake: \(error)")
        }
        return directory
    }()

    /// The child PATH for tests that start the fake without `BWClient`.
    static let searchPath = "\(pythonDirectory.path):/usr/bin:/bin"

    /// Keys the interpreter (and macOS's `/usr/bin/python3` shim, when the fake runs through it) adds before the
    /// fake runs, even under `env -i`. The fake cannot see the environment it was started with, only the
    /// interpreter's, so these are subtracted from what it logs.
    static let pythonShimKeys: Set<String> = [
        "CPATH", "LC_CTYPE", "LIBRARY_PATH", "MANPATH", "SDKROOT", "__CF_USER_TEXT_ENCODING",
    ]

    /// Values the fake accepts. Mirrors the defaults in Tests/Fixtures/bw-fake/bw.
    enum Defaults {
        static let masterPassword = "correct horse battery staple"
        static let sessionKey = "fake-session-key-0123456789abcdef"
        static let email = "tester@example.com"
        static let clientID = "user.00000000-fake-client-id"
        static let clientSecret = "fake-client-secret-abcdef"
        static let totpCode = "492039"
        static let version = "2026.9.0"
    }

    /// Fixture items used by tests.
    enum Item {
        /// GitHub: password and TOTP.
        static let github = "52b2a4be-a885-5173-8845-7cb796a3aaa2"
        static let githubPassword = "fake-pw-github-7Qx!"
        /// GitLab: password, no TOTP.
        static let gitlab = "6be6b99e-9a1e-5d74-b42f-e611ca6b5cf1"
    }

    /// The session key the fake accepts.
    static let session = SessionKey(Defaults.sessionKey)

    /// A fake that starts logged in and unlocked.
    static func unlocked() throws -> FakeBW {
        let fake = try FakeBW()
        try fake.setState("unlocked")
        return fake
    }

    /// Per-test directory passed to the fake as BITWARDENCLI_APPDATA_DIR.
    let dataDirectory: URL

    init() throws {
        dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultlight-fake-bw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    /// Generous timeouts for tests that wait for a call to finish. The fake can take seconds to start on a loaded
    /// CI runner; the spec values are asserted in `defaultTimeoutsMatchTheSpec`.
    static let patientTimeouts = BWClient.Timeouts(standard: .seconds(120), sync: .seconds(120), killGrace: .seconds(2))

    /// A client wired to this fake's data directory. HOME also points there, away from the user's.
    func client(timeouts: BWClient.Timeouts = FakeBW.patientTimeouts) -> BWClient {
        BWClient(locator: Self.locator, dataDirectory: dataDirectory, home: dataDirectory.path, timeouts: timeouts)
    }

    /// Writes `fake-config.json`. Keys are documented at the top of the fake `bw` script.
    func configure(_ config: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        try data.write(to: dataDirectory.appendingPathComponent("fake-config.json"))
    }

    /// Writes `fake-state.json`, e.g. to start a test logged in and unlocked.
    func setState(_ status: String) throws {
        let state = ["status": status, "server": "https://vault.bitwarden.com"]
        try JSONSerialization.data(withJSONObject: state).write(
            to: dataDirectory.appendingPathComponent("fake-state.json"))
    }

    /// How many two-step emails the fake `bw` has sent (`two_factor_emails` in `fake-state.json`).
    func twoFactorEmails() throws -> Int {
        let url = dataDirectory.appendingPathComponent("fake-state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return state?["two_factor_emails"] as? Int ?? 0
    }

    /// Every invocation the fake recorded: argv, the environment keys it received, overlap flag.
    func calls() throws -> [[String: Any]] {
        let url = dataDirectory.appendingPathComponent("fake-calls.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line in
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
    }

    /// argv of the last recorded call.
    func lastArguments() throws -> [String] {
        try calls().last?["argv"] as? [String] ?? []
    }

    /// Environment keys of the last recorded call, without the python shim's additions.
    func lastEnvironmentKeys() throws -> Set<String> {
        let keys = try calls().last?["env_keys"] as? [String] ?? []
        return Set(keys).subtracting(Self.pythonShimKeys)
    }
}
