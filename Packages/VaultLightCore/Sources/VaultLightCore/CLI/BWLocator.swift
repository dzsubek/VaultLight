import Foundation

/// A `bw` binary that passed the spec 7.1 checks, ready to run.
public struct BWExecutable: Sendable, Equatable {
    /// The checked file, with symlinks resolved. This is what runs, so the file checked is the file started.
    public let url: URL
    /// The child's PATH: the first Homebrew bin that exists (it has `node`) plus `/usr/bin:/bin`.
    public let searchPath: String
}

/// Finds `bw` at a configured path or the pinned Homebrew paths (spec 7.1). Never consults `PATH`.
///
/// Trust checks, all of which must pass:
/// - the binary (symlinks resolved) is owned by the user or root and not writable by group or others;
/// - on the way to the binary and to the Homebrew bin put on the child PATH, every folder passed through is owned by
///   the user or root, never writable by others, and group-writable only for wheel or admin (Homebrew's own folders
///   are `user:admin 775`), and every symlink is owned by the user or root.
public struct BWLocator: Sendable {
    /// Apple Silicon first, then Intel.
    public static let pinnedPaths = ["/opt/homebrew/bin/bw", "/usr/local/bin/bw"]
    /// Folders that go on the child PATH, in the same order. A configured path's own folder never does.
    public static let homebrewBinDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// wheel and admin: their members can already become root.
    private static let trustedGroups: Set<gid_t> = [0, 80]

    let candidates: [String]
    let homebrewBinDirectories: [String]
    let currentUserID: uid_t

    /// Everything is injectable so tests never depend on a real `bw` or Homebrew.
    public init(
        candidates: [String] = BWLocator.pinnedPaths,
        homebrewBinDirectories: [String] = BWLocator.homebrewBinDirectories, currentUserID: uid_t = getuid()
    ) {
        self.candidates = candidates
        self.homebrewBinDirectories = homebrewBinDirectories
        self.currentUserID = currentUserID
    }

    /// Returns the first existing candidate, or the configured path alone when one is set.
    ///
    /// - Throws: `BWError.notInstalled` when nothing executable is there; `BWError.unsafeBinary` when a trust
    ///   check fails.
    public func locate(configuredPath: String? = nil) throws -> BWExecutable {
        let paths = configuredPath.map { [$0] } ?? candidates
        guard let entry = paths.first(where: { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) })
        else { throw BWError.notInstalled }

        let resolved = try resolveChecked(entry)
        guard let file = Self.ownership(of: resolved), file.type == .typeRegular,
            FileManager.default.isExecutableFile(atPath: resolved)
        else { throw BWError.notInstalled }
        guard file.owner == currentUserID || file.owner == 0, file.permissions & 0o022 == 0 else {
            throw BWError.unsafeBinary
        }

        let homebrewBin = homebrewBinDirectories.first { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        if let homebrewBin { try checkTrustedFolder(resolveChecked(homebrewBin)) }

        let searchPath = ((homebrewBin.map { [$0] } ?? []) + ["/usr/bin", "/bin"]).joined(separator: ":")
        return BWExecutable(url: URL(fileURLWithPath: resolved), searchPath: searchPath)
    }

    static func isTrustedFolder(owner: uid_t, group: gid_t, permissions: Int, currentUserID: uid_t) -> Bool {
        guard owner == currentUserID || owner == 0, permissions & 0o002 == 0 else { return false }
        return permissions & 0o020 == 0 || trustedGroups.contains(group)
    }

    /// Resolves `path` one component at a time from `/`, the way the kernel does, but checks before it follows:
    /// every folder passed through must be trusted, and every link (file or folder) must be owned by the user or
    /// root. So no shared folder is skipped, whether it holds the file, a link to it, or a link to a folder on the
    /// way. Returns the real path of the last component, which the caller checks.
    private func resolveChecked(_ path: String) throws -> String {
        var pending = Self.components(of: path)
        var resolved = "/"
        try checkTrustedFolder(resolved)
        var hops = 0
        while !pending.isEmpty {
            let name = pending.removeFirst()
            if name == "." { continue }
            if name == ".." {
                resolved = (resolved as NSString).deletingLastPathComponent  // an already checked ancestor
                continue
            }
            let candidate = (resolved as NSString).appendingPathComponent(name)
            guard let info = Self.ownership(of: candidate) else { throw BWError.notInstalled }
            if info.type == .typeSymbolicLink {
                hops += 1
                guard info.owner == currentUserID || info.owner == 0, hops <= Self.maximumLinkHops,
                    let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate)
                else { throw BWError.unsafeBinary }
                if destination.hasPrefix("/") { resolved = "/" }
                pending = Self.components(of: destination) + pending
            } else if pending.isEmpty {
                return candidate
            } else {
                guard info.type == .typeDirectory else { throw BWError.notInstalled }
                try checkTrustedFolder(candidate)
                resolved = candidate
            }
        }
        return resolved
    }

    private static let maximumLinkHops = 32

    private static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private func checkTrustedFolder(_ path: String) throws {
        guard let info = Self.ownership(of: path), info.type == .typeDirectory,
            Self.isTrustedFolder(
                owner: info.owner, group: info.group, permissions: info.permissions, currentUserID: currentUserID)
        else { throw BWError.unsafeBinary }
    }

    private struct Ownership {
        let type: FileAttributeType?
        let owner: uid_t
        let group: gid_t
        let permissions: Int
    }

    /// Attributes of the path itself (a symlink is not followed; it reports `.typeSymbolicLink`).
    private static func ownership(of path: String) -> Ownership? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
            let group = (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value,
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        else { return nil }
        return Ownership(
            type: attributes[.type] as? FileAttributeType, owner: owner, group: group, permissions: permissions)
    }
}
