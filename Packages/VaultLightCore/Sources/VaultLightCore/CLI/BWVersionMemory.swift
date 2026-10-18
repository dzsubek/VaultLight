import Foundation

/// Remembers a `bw --version` that passed (spec 7.4), across launches, for one binary: its resolved path,
/// modification date, size, device, inode and change time. `bw --version` costs over a second, and the version only
/// changes with the file. A `brew upgrade`, another path or a replaced file doesn't match and is checked again.
///
/// Not a safety check: the binary's location, owner and permissions are still checked before every call (spec 7.1).
/// Non-secret: a path, file metadata and a version number. A minimum version raised for a security reason must not
/// rely on this memory: `version(for:)` compares with the current `BWClient.minimumVersion`, so raising it checks
/// every binary again.
public struct BWVersionMemory: Sendable {
    public static let key = "bwVersionCheck"

    /// `UserDefaults` is documented as thread-safe but not marked `Sendable`; it is only read and set here.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The remembered version, if `executable` is the binary it was checked for and it still meets the minimum.
    func version(for executable: URL) -> BWVersion? {
        guard let record = defaults.dictionary(forKey: Self.key),
            let fingerprint = Fingerprint(of: executable), fingerprint == Fingerprint(record: record),
            let text = record["version"] as? String, let version = BWVersion(text),
            version >= BWClient.minimumVersion
        else { return nil }
        return version
    }

    /// Remembers `version` for `executable` as it was before the check (`before`), only if it is still the same file.
    func remember(_ version: BWVersion, for executable: URL, before: Fingerprint?) {
        guard let before, before == Fingerprint(of: executable) else { return }
        defaults.set(before.record(version: version), forKey: Self.key)
    }

    /// What identifies one binary on disk. The owner can reset the modification date (`touch -r`) and match the size,
    /// but not the change time, which moves on every write, `chmod` or rename into place; a replaced file also gets
    /// another inode.
    struct Fingerprint: Equatable {
        let path: String
        let modified: Double
        let size: Int64
        let device: Int64
        let inode: Int64
        let changed: Double

        init?(of executable: URL) {
            let path = executable.resolvingSymlinksInPath().path
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            self.path = path
            modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            size = Int64(info.st_size)
            device = Int64(info.st_dev)
            inode = Int64(bitPattern: UInt64(info.st_ino))
            changed = Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1e9
        }

        init?(record: [String: Any]) {
            guard let path = record["path"] as? String, let modified = record["modified"] as? Double,
                let changed = record["changed"] as? Double,
                let size = (record["size"] as? NSNumber)?.int64Value,
                let device = (record["device"] as? NSNumber)?.int64Value,
                let inode = (record["inode"] as? NSNumber)?.int64Value
            else { return nil }
            self.path = path
            self.modified = modified
            self.size = size
            self.device = device
            self.inode = inode
            self.changed = changed
        }

        func record(version: BWVersion) -> [String: Any] {
            [
                "path": path, "modified": modified, "size": size, "device": device, "inode": inode,
                "changed": changed, "version": version.description,
            ]
        }
    }
}
