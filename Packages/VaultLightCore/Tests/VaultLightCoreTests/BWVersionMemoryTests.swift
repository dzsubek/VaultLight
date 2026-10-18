import Foundation
import Testing

@testable import VaultLightCore

/// Spec 7.4 "bw too old" without `bw --version` (1.3 s) on every launch: a version that
/// passed is remembered for one binary (resolved path, modification date, size), and anything else checks again.
final class BWVersionMemoryTests {
    let fake: FakeBW
    let suiteName = "com.vaultlight.test.version.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        fake = try FakeBW.unlocked()
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var memory: BWVersionMemory { BWVersionMemory(defaults: defaults) }

    /// A client as a new launch would make it: its own in-memory check, the shared memory.
    func launch() -> BWClient {
        BWClient(
            locator: FakeBW.locator, dataDirectory: fake.dataDirectory, home: fake.dataDirectory.path,
            timeouts: FakeBW.patientTimeouts, versionMemory: memory)
    }

    func versionCalls() throws -> Int {
        try fake.calls().filter { ($0["argv"] as? [String])?.first == "--version" }.count
    }

    func storedRecord() throws -> [String: Any] {
        try #require(defaults.dictionary(forKey: BWVersionMemory.key))
    }

    func changeRecord(_ field: String, to value: Any) throws {
        var record = try storedRecord()
        record[field] = value
        defaults.set(record, forKey: BWVersionMemory.key)
    }

    @Test func aRememberedVersionSkipsBWVersionOnTheNextLaunch() async throws {
        #expect(try await launch().checkVersion().description == FakeBW.Defaults.version)
        #expect(try versionCalls() == 1)
        #expect(try await launch().checkVersion().description == FakeBW.Defaults.version)
        #expect(try versionCalls() == 1)
    }

    @Test func theRecordHoldsTheBinaryAndTheVersionOnly() async throws {
        try await launch().checkVersion()
        #expect(defaults.dictionaryRepresentation().keys.filter { $0 == BWVersionMemory.key }.count == 1)
        let record = try storedRecord()
        #expect(Set(record.keys) == ["path", "modified", "size", "version"])
        #expect(record["path"] as? String == FakeBW.executable.resolvingSymlinksInPath().path)
        #expect(record["version"] as? String == FakeBW.Defaults.version)
    }

    @Test(arguments: ["path", "modified", "size"])
    func aChangedBinaryIsCheckedAgain(_ field: String) async throws {
        try await launch().checkVersion()
        switch field {
        case "path": try changeRecord("path", to: "/opt/homebrew/Cellar/bitwarden-cli/2025.1.0/bin/bw")
        case "modified": try changeRecord("modified", to: 1_000.0)
        default: try changeRecord("size", to: 1)
        }
        try await launch().checkVersion()
        #expect(try versionCalls() == 2)
        // The new check is remembered for the binary as it is now.
        try await launch().checkVersion()
        #expect(try versionCalls() == 2)
    }

    @Test func aRememberedVersionBelowTheMinimumIsCheckedAgain() async throws {
        try await launch().checkVersion()
        try changeRecord("version", to: "2024.6.1")
        try await launch().checkVersion()
        #expect(try versionCalls() == 2)
        #expect(try storedRecord()["version"] as? String == FakeBW.Defaults.version)
    }

    @Test func anUnreadableRecordIsCheckedAgain() async throws {
        defaults.set("not a record", forKey: BWVersionMemory.key)
        try await launch().checkVersion()
        #expect(try versionCalls() == 1)
        #expect(try storedRecord()["version"] as? String == FakeBW.Defaults.version)
    }

    @Test func aTooOldBinaryIsNeverRemembered() async throws {
        try fake.configure(["version": "2024.6.1"])
        await #expect(throws: BWError.tooOld(installed: "2024.6.1")) { try await self.launch().checkVersion() }
        #expect(defaults.object(forKey: BWVersionMemory.key) == nil)
        await #expect(throws: BWError.tooOld(installed: "2024.6.1")) { try await self.launch().checkVersion() }
        #expect(try versionCalls() == 2)
    }

    @Test func withoutMemoryEveryLaunchChecks() async throws {
        try await fake.client().checkVersion()
        try await fake.client().checkVersion()
        #expect(try versionCalls() == 2)
    }
}
