import SwiftUI
import VaultLightCore

/// One result row (spec 5.2, design 02): monogram, name, "username · host", TOTP badge and folder or
/// organization pill. No favicons, no network.
struct ResultRow: View {
    let result: SearchResult
    let query: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            monogram
            VStack(alignment: .leading, spacing: 1) {
                Highlighted.text(
                    result.entry.name, match: nameMatch, font: .system(size: 15, weight: .medium),
                    matchFont: .system(size: 15, weight: .bold)
                )
                .lineLimit(1)
                detailLine
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if result.entry.hasTOTP { totpBadge }
            pill
            if isSelected { returnChip }
        }
        .padding(.horizontal, 12)
        .frame(height: PanelMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Theme.selectionFill : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var nameMatch: String? {
        Highlighted.range(of: trimmedQuery, in: result.entry.name) == nil ? nil : trimmedQuery
    }

    /// The host is highlighted only when the name has no match (the row matched on its host).
    private var hostMatch: String? {
        guard nameMatch == nil, let host = result.entry.primaryHost,
            Highlighted.range(of: trimmedQuery, in: host) != nil
        else { return nil }
        return trimmedQuery
    }

    private var detailLine: Text {
        let username = result.entry.username.flatMap { $0.isEmpty ? nil : $0 }
        let host = result.entry.primaryHost.map { Highlighted.text($0, match: hostMatch) }
        switch (username, host) {
        case (let username?, let host?): return Text(username) + Text("  ·  ") + host
        case (let username?, nil): return Text(username)
        case (nil, let host?): return host
        case (nil, nil): return Text("")
        }
    }

    private var monogram: some View {
        let name = result.entry.name
        return Text(Monogram.letter(for: name))
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Monogram.foreground(for: name))
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Monogram.background(for: name))
            )
            .accessibilityHidden(true)
    }

    private var totpBadge: some View {
        Text("TOTP")
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
            )
    }

    @ViewBuilder private var pill: some View {
        if let organization = result.organizationName {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.teal)
                    .frame(width: 7, height: 7)
                Text(organization)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.teal)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.orgPillFill))
        } else if let folder = result.folderName {
            Text(folder)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
    }

    private var returnChip: some View {
        Image(systemName: "return")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.teal))
            .accessibilityHidden(true)
    }

    private var accessibilityText: String {
        var parts = [result.entry.name]
        if let username = result.entry.username, !username.isEmpty { parts.append(username) }
        if let host = result.entry.primaryHost { parts.append(host) }
        if let place = result.organizationName ?? result.folderName { parts.append(place) }
        if result.entry.hasTOTP { parts.append("has one-time code") }
        return parts.joined(separator: ", ")
    }
}

/// Bold for the first case- and diacritic-insensitive occurrence of a query in a string.
enum Highlighted {
    static func range(of query: String, in text: String) -> Range<String.Index>? {
        guard !query.isEmpty else { return nil }
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
    }

    /// Fonts are set per segment: a font set on the combined `Text` would override the bold part.
    static func text(_ text: String, match: String?, font: Font? = nil, matchFont: Font? = nil) -> Text {
        guard let match, let range = range(of: match, in: text) else { return Text(text).font(font) }
        return Text(text[..<range.lowerBound]).font(font)
            + Text(text[range]).font(matchFont ?? font).bold()
            + Text(text[range.upperBound...]).font(font)
    }
}
