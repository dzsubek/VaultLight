import Foundation

/// What `bw list` returned, decoded to metadata only.
struct VaultListing {
    let entries: [VaultEntry]
    let folders: [VaultFolder]
    let organizations: [VaultOrganization]
}

extension BWClient {
    /// `bw list items`, folders and organizations: the index after a sync.
    func listVault(session: SessionKey) async throws -> VaultListing {
        let entries = try await listEntries(session: session)
        let names = try await listNames(session: session)
        return VaultListing(entries: entries, folders: names.folders, organizations: names.organizations)
    }

    /// `bw list items` alone: enough for search. Each `bw` call takes seconds.
    func listEntries(session: SessionKey) async throws -> [VaultEntry] {
        let listed: [VaultEntry.Listed] = try await listItems(session: session)
        return listed.compactMap(\.entry)
    }

    /// The folder and organization names the result rows show.
    func listNames(session: SessionKey) async throws -> (folders: [VaultFolder], organizations: [VaultOrganization]) {
        let folders: [VaultFolder] = try await listFolders(session: session)
        let organizations: [VaultOrganization] = try await listOrganizations(session: session)
        return (folders, organizations)
    }
}
