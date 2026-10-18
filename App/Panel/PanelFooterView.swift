import SwiftUI
import VaultLightCore

/// The footer (spec 5.4, design 03/04/05): the status on the left, key hints on the
/// right. After a password or code copy, the right side shows the clipboard countdown instead (spec 6.2).
struct PanelFooterView: View {
    let footer: PanelFooter
    let hasSelection: Bool
    let isTOTPAvailable: Bool
    /// From `ClipboardManager`: seconds until the copied secret is cleared, `nil` when none is pending.
    let secondsUntilClear: Int?
    let clearAfter: Duration

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
                Circle().stroke(Theme.teal.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: fraction)
                    .stroke(Theme.teal, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            Text("Clears in \(seconds)s")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clipboard clears in \(seconds) seconds")
    }

    private func hint(key: String, label: String, dimmed: Bool) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 5)
                .frame(minWidth: 22, minHeight: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.chipFill))
            Text(label).font(.system(size: 13))
        }
        .foregroundStyle(.secondary)
        .opacity(dimmed ? 0.4 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(key == "↵" ? "Return" : key), \(label)")
        .accessibilityHidden(dimmed)
    }
}

extension PanelFooter {
    /// The footer confirms a password or code copy, the copies that are cleared on a timer (spec 6.2).
    var confirmsSecretCopy: Bool { self == .passwordCopied || self == .codeCopied }
}
