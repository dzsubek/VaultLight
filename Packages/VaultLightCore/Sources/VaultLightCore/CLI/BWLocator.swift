import Foundation

/// A `bw` binary that passed the spec 7.1 checks, ready to run.
public struct BWExecutable: Sendable, Equatable {
    /// The checked file, with symlinks resolved. This is what runs, so the file checked is the file started.
    public let url: URL
    /// The child's PATH: the directory `bw` was found in (the Homebrew bin, which has `node`) plus `/usr/bin:/bin`.
    public let searchPath: String
}

/// Finds `bw` at a configured path or the pinned Homebrew paths (spec 7.1). Never consults `PATH`.
public struct BWLocator: Sendable {
    /// Apple Silicon first, then Intel.
    public static let pinnedPaths = ["/opt/homebrew/bin/bw", "/usr/local/bin/bw"]

    let candidates: [String]
    let currentUserID: uid_t

    /// `candidates` and `currentUserID` are injectable so tests never depend on a real `bw`.
    public init(candidates: [String] = BWLocator.pinnedPaths, currentUserID: uid_t = getuid()) {
        self.candidates = candidates
        self.currentUserID = currentUserID
    }

    /// Returns the first existing candidate, or the configured path alone when one is set.
    ///
    /// - Throws: `BWError.notInstalled` when nothing executable is there; `BWError.unsafeBinary` when the
    ///   binary is owned by someone other than the user or root, or is writable by group or others.
    public func locate(configuredPath: String? = nil) throws -> BWExecutable {
        let paths = configuredPath.map { [$0] } ?? candidates
        guard let entry = paths.first(where: { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) })
        else { throw BWError.notInstalled }

        let entryURL = URL(fileURLWithPath: entry).standardizedFileURL
        let resolved = entryURL.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            FileManager.default.isExecutableFile(atPath: resolved.path)
        else { throw BWError.notInstalled }

        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        guard let owner, owner == currentUserID || owner == 0,
            let permissions, permissions & 0o022 == 0
        else { throw BWError.unsafeBinary }

        return BWExecutable(url: resolved, searchPath: entryURL.deletingLastPathComponent().path + ":/usr/bin:/bin")
    }
}
