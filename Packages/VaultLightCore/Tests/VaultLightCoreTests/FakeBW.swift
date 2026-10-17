import Foundation

/// Locates and configures the fake `bw` CLI in `Tests/Fixtures/bw-fake`.
///
/// Each test gets its own data directory (the fake keeps state, config and a call log there),
/// so tests can run in parallel without sharing state.
struct FakeBW {
    /// Repository root, derived from this file's location:
    /// <root>/Packages/VaultLightCore/Tests/VaultLightCoreTests/FakeBW.swift
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // VaultLightCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // VaultLightCore
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // <root>

    static let executable: URL = repositoryRoot.appendingPathComponent("Tests/Fixtures/bw-fake/bw")

    /// Values the fake accepts. Mirrors the defaults in Tests/Fixtures/bw-fake/bw.
    enum Defaults {
        static let masterPassword = "correct horse battery staple"
        static let sessionKey = "fake-session-key-0123456789abcdef"
        static let email = "tester@example.com"
        static let clientID = "user.00000000-fake-client-id"
        static let clientSecret = "fake-client-secret-abcdef"
    }

    /// Per-test directory passed to the fake as BITWARDENCLI_APPDATA_DIR.
    let dataDirectory: URL

    init() throws {
        dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultlight-fake-bw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    }

    /// Writes `fake-config.json`. Keys are documented at the top of the fake `bw` script.
    func configure(_ config: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        try data.write(to: dataDirectory.appendingPathComponent("fake-config.json"))
    }

    /// Every invocation the fake recorded: argv and the environment keys it received.
    func calls() throws -> [[String: Any]] {
        let url = dataDirectory.appendingPathComponent("fake-calls.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line in
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
    }
}
