import Foundation

/// Remembers a `bw --version` that passed (spec 7.4), across launches, for one binary: its resolved path,
/// modification date and size. `bw --version` costs over a second, and the version only
/// changes with the file. A `brew upgrade`, another path or a replaced file doesn't match and is checked again.
///
/// Not a safety check: the binary's location, owner and permissions are still checked before every call (spec 7.1).
/// Non-secret: a path, a date, a size and a version number.
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

    /// What identifies one binary on disk.
    struct Fingerprint: Equatable {
        let path: String
        let modified: Double
        let size: Int64

        init?(of executable: URL) {
            let path = executable.resolvingSymlinksInPath().path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                let modified = attributes[.modificationDate] as? Date,
                let size = (attributes[.size] as? NSNumber)?.int64Value
            else { return nil }
            self.path = path
            self.modified = modified.timeIntervalSince1970
            self.size = size
        }

        init?(record: [String: Any]) {
            guard let path = record["path"] as? String, let modified = record["modified"] as? Double,
                let size = (record["size"] as? NSNumber)?.int64Value
            else { return nil }
            self.path = path
            self.modified = modified
            self.size = size
        }

        func record(version: BWVersion) -> [String: Any] {
            ["path": path, "modified": modified, "size": size, "version": version.description]
        }
    }
}
