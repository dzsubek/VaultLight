import Foundation
import Testing

@testable import VaultLightCore

/// Spec 7.1 "One at a time" and "Timeouts", plus client setup.
@Suite("BWClient queue and timeouts")
struct BWClientQueueTests {
    // MARK: Serial queue

    @Test func callsRunOneAtATime() async throws {
        let fake = try FakeBW()
        try fake.configure(["delay": ["status": 0.3]])
        let client = fake.client()
        try await withThrowingTaskGroup(of: BWStatus.self) { group in
            for _ in 0..<4 { group.addTask { try await client.status() } }
            for try await status in group { #expect(status.state == .unauthenticated) }
        }
        let calls = try fake.calls()
        #expect(calls.count == 4)
        #expect(calls.allSatisfy { $0["concurrent"] as? Bool == false })
    }

    // MARK: Timeouts

    @Test func defaultTimeoutsMatchTheSpec() {
        #expect(
            BWClient.Timeouts.default
                == BWClient.Timeouts(standard: .seconds(15), sync: .seconds(60), killGrace: .seconds(2)))
    }

    /// Sync gets the longer timeout; every other call gets the standard one. A timed-out call frees the queue.
    @Test func syncUsesTheSyncTimeout() async throws {
        let fake = try FakeBW.unlocked()
        try fake.configure(["delay": ["sync": 1.5, "status": 30]])
        let client = fake.client(
            timeouts: BWClient.Timeouts(standard: .milliseconds(700), sync: .seconds(10), killGrace: .seconds(1)))
        await #expect(throws: BWError.timeout) { try await client.status(session: FakeBW.session) }
        try await client.sync(session: FakeBW.session)
    }

    // MARK: Misc

    @Test func missingBinaryIsNotInstalled() async throws {
        let fake = try FakeBW()
        let client = BWClient(
            locator: BWLocator(candidates: ["/nonexistent/bw"], homebrewBinDirectories: []),
            dataDirectory: fake.dataDirectory, home: fake.dataDirectory.path)
        await #expect(throws: BWError.notInstalled) { try await client.status() }
    }

    /// The binary is located and checked again right before every call, so a later swap, a `brew upgrade` or a
    /// permission change is seen.
    @Test func binaryIsCheckedBeforeEveryCall() async throws {
        let fake = try FakeBW()
        let folder = fake.dataDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("bw")
        try FileManager.default.copyItem(at: FakeBW.executable, to: copy)
        let client = BWClient(
            locator: BWLocator(candidates: [copy.path], homebrewBinDirectories: []), dataDirectory: fake.dataDirectory,
            home: fake.dataDirectory.path)
        _ = try await client.version()

        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: copy.path)
        await #expect(throws: BWError.unsafeBinary) { try await client.version() }

        try FileManager.default.removeItem(at: copy)
        await #expect(throws: BWError.notInstalled) { try await client.version() }
    }

    @Test func dataDirectoryIsCreatedPrivate() async throws {
        let fake = try FakeBW()
        let directory = fake.dataDirectory.appendingPathComponent("VaultLight/bw", isDirectory: true)
        let client = BWClient(locator: FakeBW.locator, dataDirectory: directory, home: fake.dataDirectory.path)
        _ = try await client.status()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    /// A data folder that already exists with wider permissions is tightened before use.
    @Test func existingDataDirectoryIsMadePrivate() async throws {
        let fake = try FakeBW()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.dataDirectory.path)
        _ = try await fake.client().status()
        let attributes = try FileManager.default.attributesOfItem(atPath: fake.dataDirectory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func defaultDataDirectoryIsVaultLightsOwn() {
        #expect(BWClient.defaultDataDirectory.path.hasSuffix("/Library/Application Support/VaultLight/bw"))
    }

    @Test func sessionKeyNeverPrintsItsValue() {
        let key = SessionKey("very-secret")
        #expect(!"\(key)".contains("very-secret"))
        #expect(!String(reflecting: key).contains("very-secret"))
        var dumped = ""
        dump(key, to: &dumped)
        #expect(!dumped.contains("very-secret"))
    }
}
