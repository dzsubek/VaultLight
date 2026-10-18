import SwiftUI
import VaultLightCore

/// The footer (spec 5.4, design 03/04/05): the status on the left, key hints on the
/// right. While a copied secret is on the clipboard the footer shows its countdown (spec 6.2): on the right, in
/// place of the hints, with the copy confirmation (design 04); on the left when the panel is reopened before the
/// clear, so the hints stay.
struct PanelFooterView: View {
    let footer: PanelFooter
    let hasSelection: Bool
    let isTOTPAvailable: Bool
    /// From `ClipboardManager`: seconds until the copied secret is cleared, `nil` when none is pending.
    let secondsUntilClear: Int?
    let clearAfter: Duration
    /// The warning after a failed sync, shown while nothing else is (spec 7.4 "Offline").
    var syncNotice: SyncNotice?
    /// "Try again" after a failed copy or a timeout (design 16); `nil` when there is nothing to repeat.
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            status
            Spacer(minLength: 12)
            if footer.confirmsSecretCopy, let secondsUntilClear {
                countdown(secondsUntilClear)
            } else {
                HStack(spacing: 14) {
                    hint(key: "↵", label: "Copy password", dimmed: !hasSelection)
                    hint(key: "⌘U", label: "Username", dimmed: !hasSelection)
                    hint(key: "⌘T", label: "Code", dimmed: !hasSelection || !isTOTPAvailable)
                    hint(key: "⌘O", label: "Open", dimmed: !hasSelection)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: PanelMetrics.footerHeight)
        .background(Color.primary.opacity(0.025))
    }

    @ViewBuilder private var status: some View {
        if let message = footer.message {
            HStack(spacing: 8) {
                indicator
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let onRetry {
                    Button("Try again", action: onRetry)
                        .buttonStyle(CompactButtonStyle())
                }
            }
            .accessibilityElement(children: .contain)
        } else if let secondsUntilClear {
            countdown(secondsUntilClear)
        } else if let syncNotice {
            HStack(spacing: 8) {
                StatusDot(color: syncNotice == .offline ? Theme.amber : Theme.red)
                Text(syncNotice.message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var indicator: some View {
        switch footer {
        case .usernameCopied, .passwordCopied, .codeCopied:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
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
            Text("Clears in \(seconds)s")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clipboard clears in \(seconds) seconds")
    }

    private func hint(key: String, label: String, dimmed: Bool) -> some View {
        KeyHint(key: key, label: label)
            .opacity(dimmed ? 0.4 : 1)
            .accessibilityHidden(dimmed)
    }
}

extension PanelFooter {
    /// The footer confirms a password or code copy, the copies that are cleared on a timer (spec 6.2).
    var confirmsSecretCopy: Bool { self == .passwordCopied || self == .codeCopied }
}
