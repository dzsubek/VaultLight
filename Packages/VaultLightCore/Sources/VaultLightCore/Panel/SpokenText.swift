import Foundation

extension SearchResult {
    /// What VoiceOver reads for a row (spec 10, NOTES.md screen 1): name, username, host, organization or folder,
    /// and "has one-time code". Spoken only, never logged.
    public var spokenDescription: String {
        var parts = [entry.name]
        if let username = entry.username, !username.isEmpty { parts.append(username) }
        if let host = entry.primaryHost { parts.append(host) }
        if let place = organizationName ?? folderName { parts.append(place) }
        if entry.hasTOTP { parts.append(String(localized: "has one-time code", bundle: .module)) }
        return parts.joined(separator: ", ")
    }
}

extension PanelViewModel {
    /// What the panel announces when the selection or the list changes. Focus never leaves the search field
    /// (NOTES.md screen 1), so VoiceOver would otherwise not hear ↑/↓ or an empty result.
    public var spokenSelection: String? {
        if let selected { return selected.spokenDescription }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(localized: "No matches for “\(trimmed)”", bundle: .module)
    }
}
