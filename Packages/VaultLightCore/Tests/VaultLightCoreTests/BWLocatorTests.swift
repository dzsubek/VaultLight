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

        func makeDirectory(_ name: String, permissions: Int = 0o755) throws -> URL {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            return url
        }

        func makeBinary(_ name: String = "bw", permissions: Int = 0o755, in folder: URL? = nil) throws -> URL {
            let url = (folder ?? directory).appendingPathComponent(name)
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

    /// The child PATH is the first Homebrew bin that exists plus /usr/bin:/bin, never the folder of a
    /// configured path (spec 7.1).
    @Test func searchPathIsTheHomebrewBinPlusSystemPaths() throws {
        let scratch = try Scratch()
        let custom = try scratch.makeBinary()
        let homebrew = try scratch.makeDirectory("homebrew-bin")
        let missing = scratch.directory.appendingPathComponent("missing").path
        let locator = BWLocator(candidates: [], homebrewBinDirectories: [missing, homebrew.path])
        let executable = try locator.locate(configuredPath: custom.path)
        #expect(executable.searchPath == "\(homebrew.path):/usr/bin:/bin")

        let bare = try BWLocator(candidates: [custom.path], homebrewBinDirectories: [missing]).locate()
        #expect(bare.searchPath == "/usr/bin:/bin")
    }

    @Test func defaultHomebrewBinsMatchThePinnedPaths() {
        #expect(BWLocator.homebrewBinDirectories == ["/opt/homebrew/bin", "/usr/local/bin"])
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
        let executable = try BWLocator(candidates: ["/bin/ls"], homebrewBinDirectories: [], currentUserID: getuid() + 1)
            .locate()
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
    }

    /// A folder others can write to lets them swap the binary or plant files, so it is refused, both where the
    /// path points and where the file really is.
    @Test(arguments: [0o777, 0o757])
    func refusesBinaryInFolderOthersCanWrite(permissions: Int) throws {
        let scratch = try Scratch()
        let shared = try scratch.makeDirectory("shared")
        let binary = try scratch.makeBinary(in: shared)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: shared.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shared.path) }
        #expect(throws: BWError.unsafeBinary) { try BWLocator(candidates: []).locate(configuredPath: binary.path) }
    }

    /// The security review's scenario: a `bw` symlink in a shared folder pointing at a root-owned tool.
    @Test func refusesSymlinkInSharedFolderEvenWhenTargetIsRootOwned() throws {
        let scratch = try Scratch()
        let shared = try scratch.makeDirectory("shared", permissions: 0o777)
        let link = shared.appendingPathComponent("bw")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        #expect(throws: BWError.unsafeBinary) { try BWLocator(candidates: []).locate(configuredPath: link.path) }
    }

    /// Group-writable folders are allowed only for wheel and admin (Homebrew's /opt/homebrew/bin is user:admin 775).
    @Test func folderTrustRules() {
        let user = getuid()
        func trusted(_ owner: uid_t, _ group: gid_t, _ permissions: Int) -> Bool {
            BWLocator.isTrustedFolder(owner: owner, group: group, permissions: permissions, currentUserID: user)
        }
        #expect(trusted(user, 20, 0o755))
        #expect(trusted(0, 0, 0o755))
        #expect(trusted(user, 80, 0o775))
        #expect(trusted(0, 0, 0o775))
        #expect(!trusted(user, 20, 0o775))
        #expect(!trusted(user, 80, 0o777))
        #expect(!trusted(0, 0, 0o1777))
        #expect(!trusted(user + 1, 20, 0o755))
    }

    @Test func findsTheFakeBW() throws {
        let executable = try FakeBW.locator.locate()
        #expect(executable.url == FakeBW.executable.resolvingSymlinksInPath())
    }
}
