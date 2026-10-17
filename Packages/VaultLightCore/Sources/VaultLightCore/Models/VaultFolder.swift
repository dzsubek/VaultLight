/// One element of `bw list folders`, so result rows can show the folder name (spec 5.2).
public struct VaultFolder: Decodable, Sendable, Equatable {
    /// `nil` for the "No Folder" entry `bw` lists.
    public let id: String?
    public let name: String

    public init(id: String?, name: String) {
        self.id = id
        self.name = name
    }
}

/// One element of `bw list organizations`, so result rows can show the organization name (spec 5.2).
public struct VaultOrganization: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
