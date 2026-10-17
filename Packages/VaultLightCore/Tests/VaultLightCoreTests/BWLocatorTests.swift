import Foundation
import Testing

@testable import VaultLightCore

/// Spec 7.1 "Pinned binary".
@Suite("BWLocator")
struct BWLocatorTests {
    /// A scratch directory with a stand-in `bw`, removed on deinit.
    final class Scratch {
        let directory: URL
        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("vaultlight-locator-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }

        func makeBinary(_ name: String = "bw", permissions: Int = 0o755) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data("#!/bin/false\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            return url
        }
    }

    @Test func defaultCandidatesAreTheTwoPinnedHomebrewPaths() {
        #expect(BWLocator.pinnedPaths == ["/opt/homebrew/bin/bw", "/usr/local/bin/bw"])
        #expect(BWLocator().candidates == BWLocator.pinnedPaths)
    }

    @Test func findsFirstExistingCandidateInOrder() throws {
        let scratch = try Scratch()
        let second = try scratch.makeBinary("bw-second")
        let missing = scratch.directory.appendingPathComponent("missing").path
        let executable = try BWLocator(candidates: [missing, second.path]).locate()
        #expect(executable.url == second.resolvingSymlinksInPath())
    }

    /// The child PATH is the directory bw was found in (the Homebrew bin) plus /usr/bin:/bin.
    @Test func searchPathIsTheBinaryDirectoryPlusSystemPaths() throws {
        let scratch = try Scratch()
        let binary = try scratch.makeBinary()
        let executable = try BWLocator(candidates: [binary.path]).locate()
        #expect(executable.searchPath == "\(scratch.directory.path):/usr/bin:/bin")
    }

    /// Never resolves through PATH: with no candidate on disk, nothing is found, even though
    /// a `bw` may exist on the test process's PATH.
    @Test func doesNotFallBackToPATH() throws {
        let scratch = try Scratch()
        let missing = scratch.directory.appendingPathComponent("bw").path
        #expect(throws: BWError.notInstalled) { try BWLocator(candidates: [missing]).locate() }
        #expect(throws: BWError.notInstalled) { try BWLocator(candidates: []).locate() }
    }

    @Test func configuredPathIsUsedInsteadOfCandidates() throws {
        let scratch = try Scratch()
        let pinned = try scratch.makeBinary("pinned")
        let custom = try scratch.makeBinary("custom")
        let executable = try BWLocator(candidates: [pinned.path]).locate(configuredPath: custom.path)
        #expect(executable.url == custom.resolvingSymlinksInPath())
    }

    /// A configured path that doesn't work never falls back silently to the pinned paths.
    @Test func missingConfiguredPathDoesNotFallBack() throws {
        let scratch = try Scratch()
        let pinned = try scratch.makeBinary("pinned")
        let missing = scratch.directory.appendingPathComponent("custom").path
        #expect(throws: BWError.notInstalled) {
            try BWLocator(candidates: [pinned.path]).locate(configuredPath: missing)
        }
    }

    @Test func relativeConfiguredPathIsRejected() throws {
        #expect(throws: BWError.notInstalled) { try BWLocator(candidates: []).locate(configuredPath: "bin/bw") }
    }

    @Test func nonExecutableFileIsNotInstalled() throws {
        let scratch = try Scratch()
        let binary = try scratch.makeBinary(permissions: 0o644)
        #expect(throws: BWError.notInstalled) { try BWLocator(candidates: [binary.path]).locate() }
    }

    @Test(arguments: [0o775, 0o757, 0o777])
    func refusesBinaryWritableByGroupOrOthers(permissions: Int) throws {
        let scratch = try Scratch()
        let binary = try scratch.makeBinary(permissions: permissions)
        #expect(throws: BWError.unsafeBinary) { try BWLocator(candidates: [binary.path]).locate() }
    }

    @Test func refusesBinaryOwnedByAnotherUser() throws {
        let scratch = try Scratch()
        let binary = try scratch.makeBinary()
        let someoneElse = getuid() + 1
        #expect(throws: BWError.unsafeBinary) {
            try BWLocator(candidates: [binary.path], currentUserID: someoneElse).locate()
        }
    }

    @Test func acceptsBinaryOwnedByRoot() throws {
        // /bin/ls is root-owned and not group/other-writable on every macOS install.
        let executable = try BWLocator(candidates: ["/bin/ls"], currentUserID: getuid() + 1).locate()
        #expect(executable.url.path == "/bin/ls")
    }

    /// The check applies to the file a symlink points to, and that file is what gets run.
    @Test func followsSymlinksAndChecksTheTarget() throws {
        let scratch = try Scratch()
        let target = try scratch.makeBinary("bw.js", permissions: 0o777)
        let link = scratch.directory.appendingPathComponent("bw")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: BWError.unsafeBinary) { try BWLocator(candidates: [link.path]).locate() }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let executable = try BWLocator(candidates: [link.path]).locate()
        #expect(executable.url == target.resolvingSymlinksInPath())
        #expect(executable.searchPath.hasPrefix(link.deletingLastPathComponent().path + ":"))
    }

    @Test func findsTheFakeBW() throws {
        let executable = try FakeBW().executable()
        #expect(executable.url == FakeBW.executable.resolvingSymlinksInPath())
    }
}
