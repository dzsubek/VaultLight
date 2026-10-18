import SwiftUI
import VaultLightCore

/// The footer (spec 5.4, design 03/04/05/08): the status on the left, key hints on the right. Copy confirmations and
/// errors come first, then the clipboard countdown, then the sync line (design 08 "Priority"). While a copied secret is on the clipboard the footer shows its countdown (spec 6.2): on the right, in
/// place of the hints, with the copy confirmation (design 04); on the left when the panel is reopened before the
/// clear, so the hints stay.
struct PanelFooterView: View {
    let footer: PanelFooter
    let hasSelection: Bool
    let isTOTPAvailable: Bool
    /// From `ClipboardManager`: seconds until the copied secret is cleared, `nil` when none is pending.
    let secondsUntilClear: Int?
    let clearAfter: Duration
    /// Background sync (spec 7.3), shown while nothing else is.
    var syncStatus = SyncStatus()
    /// "Try again" after a failed copy or a timeout (design 16); `nil` when there is nothing to repeat.
    var onRetry: (() -> Void)?
    /// "Try again" after a failed sync (design 08); ⌘R does the same.
    var onSyncNow: (() -> Void)?

    var body: some View {
        // A status too long for the full hints (a "Sync failed — last synced 12 min ago" with Try again, or a longer
        // translation) keeps the key caps and drops their labels, rather than being cut off.
        ViewThatFits(in: .horizontal) {
            row(hintLabels: true)
            row(hintLabels: false)
        }
        .padding(.horizontal, 16)
        .frame(height: PanelMetrics.footerHeight)
        .background(Color.primary.opacity(0.025))
    }

    private func row(hintLabels: Bool) -> some View {
        HStack(spacing: 0) {
            status.layoutPriority(-1)
            Spacer(minLength: 2)
            if footer.confirmsSecretCopy, let secondsUntilClear {
                countdown(secondsUntilClear)
            } else {
                HStack(spacing: PanelMetrics.footerHintSpacing) {
                    hint(
                        key: "↵", label: String(localized: "Copy password"), showsLabel: hintLabels,
                        dimmed: !hasSelection)
                    hint(key: "⌘U", label: String(localized: "Username"), showsLabel: hintLabels, dimmed: !hasSelection)
                    hint(
                        key: "⌘T", label: String(localized: "Code"), showsLabel: hintLabels,
                        dimmed: !hasSelection || !isTOTPAvailable)
                    hint(key: "⌘O", label: String(localized: "Open"), showsLabel: hintLabels, dimmed: !hasSelection)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let message = footer.message {
            // The copy check sits closer to its text than a status dot does (designs 03, 04).
            HStack(spacing: footer.isCopyConfirmation ? 6 : 8) {
                indicator
                Text(message)
                    .font(.system(size: PanelMetrics.footerFontSize))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let onRetry {
                    Button("Try again", action: onRetry)
                        .buttonStyle(CompactButtonStyle())
                }
            }
            .accessibilityElement(children: .contain)
        } else if let secondsUntilClear {
            countdown(secondsUntilClear)
        } else {
            // "Synced 3 min ago" keeps counting while the panel is open (NOTES.md screen 8).
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let line = syncStatus.footerLine(now: context.date) { syncLine(line) }
            }
        }
    }

    private func syncLine(_ line: SyncLine) -> some View {
        HStack(spacing: 8) {
            StatusDot(color: line.tone.color)
            Text(line.text)
                .font(.system(size: PanelMetrics.footerFontSize))
                .foregroundStyle(line.tone == .neutral ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if line.offersRetry, let onSyncNow {
                Button("Try again", action: onSyncNow)
                    .buttonStyle(CompactButtonStyle())
                    .help("Sync now (⌘R)")
                    .accessibilityHint("Syncs the vault again. Shortcut: Command R.")
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var indicator: some View {
        switch footer {
        case .usernameCopied, .passwordCopied, .codeCopied:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.teal)
        case .noPassword, .noTOTP, .noUsername, .noURL:
            Circle().fill(Theme.amber).frame(width: 8, height: 8)
        case .copyFailed, .clipboardWriteFailed, .timedOut, .locked:
            Circle().fill(Theme.red).frame(width: 8, height: 8)
        case .idle:
            EmptyView()
        }
    }

    /// A ring that empties as the timeout runs out, then "Clears in Ns" (design 04).
    private func countdown(_ seconds: Int) -> some View {
        let fraction = max(0, min(1, Double(seconds) / (clearAfter / .seconds(1))))
        return HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Theme.teal.opacity(0.25), lineWidth: 1.5)
                Circle().trim(from: 0, to: fraction)
                    .stroke(Theme.teal, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            Text(String(localized: "Clears in \(seconds)s"))
                .font(.system(size: PanelMetrics.footerFontSize).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Clipboard clears in \(seconds) seconds"))
    }

    private func hint(key: String, label: String, showsLabel: Bool, dimmed: Bool) -> some View {
        KeyHint(key: key, label: label, showsLabel: showsLabel)
            .opacity(dimmed ? 0.4 : 1)
            .accessibilityHidden(dimmed)
    }
}

extension SyncLine.Tone {
    var color: Color {
        switch self {
        case .neutral: Color.secondary.opacity(0.6)
        case .warning: Theme.amber
        case .error: Theme.red
        }
    }
}

extension PanelFooter {
    var isCopyConfirmation: Bool { self == .usernameCopied || self == .passwordCopied || self == .codeCopied }

    /// The footer confirms a password or code copy, the copies that are cleared on a timer (spec 6.2).
    var confirmsSecretCopy: Bool { self == .passwordCopied || self == .codeCopied }
}
