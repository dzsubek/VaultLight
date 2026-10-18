import Foundation

/// What `bw list` returned, decoded to metadata only.
struct VaultListing {
    let entries: [VaultEntry]
    let folders: [VaultFolder]
    let organizations: [VaultOrganization]
}

extension BWClient {
    func listVault(session: SessionKey) async throws -> VaultListing {
        let listed: [VaultEntry.Listed] = try await listItems(session: session)
        let folders: [VaultFolder] = try await listFolders(session: session)
        let organizations: [VaultOrganization] = try await listOrganizations(session: session)
        return VaultListing(entries: listed.compactMap(\.entry), folders: folders, organizations: organizations)
    }
}
