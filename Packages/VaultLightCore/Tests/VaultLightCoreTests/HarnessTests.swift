import Foundation
import Testing

@testable import VaultLightCore

/// Harness checks.
@Suite("Harness")
struct HarnessTests {
    @Test func coreVersionIsSet() {
        #expect(!VaultLightCore.version.isEmpty)
    }

    @Test func fakeBWIsExecutable() {
        #expect(FileManager.default.isExecutableFile(atPath: FakeBW.executable.path))
    }

    /// Test support may launch the fake directly. Product code must go through the CLI wrapper.
    @Test func fakeBWReportsVersionWithMinimalEnvironment() throws {
        let fake = try FakeBW()
        let process = Process()
        process.executableURL = FakeBW.executable
        process.arguments = ["--version", "--nointeraction"]
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "BITWARDENCLI_APPDATA_DIR": fake.dataDirectory.path,
        ]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        let version = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)

        let call = try #require(try fake.calls().first)
        #expect(call["argv"] as? [String] == ["--version", "--nointeraction"])
    }
}
