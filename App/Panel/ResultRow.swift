import SwiftUI
import VaultLightCore

/// One result row (spec 5.2, design 02): monogram, name, "username · host", TOTP badge and folder or
/// organization pill. No favicons, no network. After a password or code copy, the selected row's ↵ chip turns
/// into a check (design 04).
struct ResultRow: View {
    let result: SearchResult
    let query: String
    let isSelected: Bool
    var isCopied = false

    var body: some View {
        HStack(spacing: 12) {
            monogram
            VStack(alignment: .leading, spacing: 1) {
                Highlighted.text(
                    result.entry.name, match: highlight.name, font: .system(size: 15, weight: .medium),
                    matchFont: .system(size: 15, weight: .bold)
                )
                .lineLimit(1)
                detailLine
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if result.entry.hasTOTP { totpBadge }
            pill
            if isSelected { chip }
        }
        .padding(.horizontal, 12)
        .frame(height: PanelMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Theme.selectionFill : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(result.spokenDescription)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Where the query is shown in bold, by how the row matched (spec 5.1 tiers): name tiers bold the name, the
    /// host tier the host, fuzzy the first contiguous occurrence in the host, else in the name. Rows without a
    /// tier (the empty-query list) and fuzzy matches with no contiguous occurrence show no bold.
    private var highlight: (name: String?, host: String?) {
        let text = trimmedQuery
        guard let tier = result.tier, !text.isEmpty else { return (nil, nil) }
        let inName = Highlighted.range(of: text, in: result.entry.name) != nil
        let inHost = result.entry.primaryHost.map { Highlighted.range(of: text, in: $0) != nil } ?? false
        switch tier {
        case .exact, .namePrefix, .wordPrefix: return (inName ? text : nil, nil)
        case .host: return (nil, inHost ? text : nil)
        case .fuzzy: return inHost ? (nil, text) : (inName ? text : nil, nil)
        }
    }

    private var detailLine: Text {
        let username = result.entry.username.flatMap { $0.isEmpty ? nil : $0 }
        let host = result.entry.primaryHost.map {
            Highlighted.text(
                $0, match: highlight.host, baseStyle: AnyShapeStyle(.secondary),
                matchStyle: AnyShapeStyle(.primary))
        }
        let separator = Text("  ·  ").foregroundStyle(.secondary)
        switch (username, host) {
        case (let username?, let host?): return Text(username).foregroundStyle(.secondary) + separator + host
        case (let username?, nil): return Text(username).foregroundStyle(.secondary)
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

    private var chip: some View {
        Group {
            if isCopied {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
            } else {
                Text("↵").font(.system(size: 13, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 22, height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.teal))
        .accessibilityHidden(true)
    }
}

/// Bold for the first case- and diacritic-insensitive occurrence of a query in a string.
enum Highlighted {
    static func range(of query: String, in text: String) -> Range<String.Index>? {
        guard !query.isEmpty else { return nil }
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
    }

    /// Fonts and styles are set per segment: a font set on the combined `Text` would override the bold part.
    static func text(
        _ text: String, match: String?, font: Font? = nil, matchFont: Font? = nil,
        baseStyle: AnyShapeStyle? = nil, matchStyle: AnyShapeStyle? = nil
    ) -> Text {
        func segment(_ value: Substring, font: Font?, style: AnyShapeStyle?, bold: Bool) -> Text {
            var piece = Text(value).font(font)
            if bold { piece = piece.bold() }
            if let style { piece = piece.foregroundStyle(style) }
            return piece
        }
        guard let match, let range = range(of: match, in: text) else {
            return segment(text[...], font: font, style: baseStyle, bold: false)
        }
        return segment(text[..<range.lowerBound], font: font, style: baseStyle, bold: false)
            + segment(text[range], font: matchFont ?? font, style: matchStyle ?? baseStyle, bold: true)
            + segment(text[range.upperBound...], font: font, style: baseStyle, bold: false)
    }
}
