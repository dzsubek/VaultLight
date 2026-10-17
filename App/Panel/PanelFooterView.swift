import SwiftUI
import VaultLightCore

/// The footer (spec 5.4, design 03/05): the status on the left, key hints on the
/// right.
struct PanelFooterView: View {
    let footer: PanelFooter
    let hasSelection: Bool
    let isTOTPAvailable: Bool

    var body: some View {
        HStack(spacing: 0) {
            status
            Spacer(minLength: 12)
            HStack(spacing: 14) {
                hint(key: "↵", label: "Copy password", dimmed: !hasSelection, symbol: "return")
                hint(key: "⌘U", label: "Username", dimmed: !hasSelection)
                hint(key: "⌘T", label: "Code", dimmed: !hasSelection || !isTOTPAvailable)
                hint(key: "⌘O", label: "Open", dimmed: !hasSelection)
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
        case .copyFailed, .timedOut, .locked:
            Circle().fill(Theme.red).frame(width: 8, height: 8)
        case .idle:
            EmptyView()
        }
    }

    private func hint(key: String, label: String, dimmed: Bool, symbol: String? = nil) -> some View {
        HStack(spacing: 6) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                } else {
                    Text(key).font(.system(size: 12, weight: .medium))
                }
            }
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
