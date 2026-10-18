import SwiftUI
import VaultLightCore

/// The screens that aren't search (spec 3.1, 7.4): Touch ID (design 06), master password (07), setup problems (09,
/// 16) and failures. Fixed copy only: never raw error text, never a typed secret kept anywhere but the field.
struct NonSearchView: View {
    let controller: PanelController

    var body: some View {
        switch controller.content {
        case .onboarding:
            OnboardingView(controller: controller)
        case .touchID(let canceled):
            TouchIDView(canceled: canceled, summary: controller.summary)
        case .masterPassword(let reason, let attempts, let busy):
            MasterPasswordView(
                reason: reason, attempts: attempts, busy: busy, email: controller.summary.email,
                openCount: controller.openCount, closeCount: controller.closeCount,
                onSubmit: { password in Task { await controller.unlock(masterPassword: password) } })
        case .setupProblem(let problem):
            SetupProblemView(
                problem: problem, path: controller.setupPath, copied: controller.commandCopied,
                onCopy: { controller.copySetupCommand() })
        case .failure(let failure):
            FailureView(failure: failure)
        case .checking, .unlocked:
            CheckingView()
        }
    }
}

/// The 60 pt header of the locked screens: a glyph and a gray title in the search field's place.
struct PanelTitle: View {
    let symbol: String
    let title: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(tint)
                .frame(width: 23)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: PanelMetrics.searchHeight)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Body text lines up with the title text: 20 pt edge + 23 pt glyph + 14 pt gap.
private let bodyLeading: CGFloat = 57

private struct TouchIDView: View {
    let canceled: Bool
    let summary: VaultSummary

    var body: some View {
        VStack(spacing: 0) {
            PanelTitle(symbol: "lock", title: "Vault locked")
            Divider()
            VStack(spacing: 10) {
                Image(systemName: "touchid")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(Theme.teal)
                    .accessibilityHidden(true)
                Text("Touch ID to unlock")
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.top, 6)
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                if canceled {
                    Text("Press Return to try again.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 52)
            .accessibilityElement(children: .combine)
            Divider()
            FooterBar(status: "Locked") { KeyHint(key: "↵", label: canceled ? "Try again" : nil) }
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let email = summary.email { parts.append(email) }
        if let expiry = summary.storedSessionExpiresAt, expiry > Date() {
            parts.append("stored session expires in \(RelativeTime.duration(expiry.timeIntervalSinceNow))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The master password in place of the search field (design 07). The text exists only in the field's state and is
/// cleared as soon as it is submitted, on a wrong password and whenever the panel closes.
private struct MasterPasswordView: View {
    let reason: MasterPasswordReason
    let attempts: Int
    let busy: Bool
    let email: String?
    let openCount: Int
    let closeCount: Int
    let onSubmit: (String) -> Void

    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "lock")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 23)
                    .accessibilityHidden(true)
                SecureField("Master password", text: $password)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .tint(Theme.teal)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .disabled(busy)
                    .accessibilityLabel("Master password")
                    .onSubmit(submit)
                Button(action: submit) { ReturnLabel(title: "Unlock", busy: busy) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy)
            }
            .padding(.leading, 20)
            .padding(.trailing, 14)
            .frame(height: PanelMetrics.searchHeight)
            .shake(attempts)
            Rectangle()
                .fill(attempts > 0 ? Theme.red : Color.primary.opacity(0.1))
                .frame(height: 1)
            Text(attempts > 0 ? "Wrong master password. Try again." : MasterPasswordReason.prompt(email: email))
                .font(.system(size: 14))
                .foregroundStyle(attempts > 0 ? Theme.red : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, bodyLeading)
                .padding(.trailing, 20)
                .padding(.vertical, 18)
            Divider()
            FooterBar(status: reason.footer) {
                KeyHint(key: "↵", label: "Unlock")
                KeyHint(key: "esc", label: "Close")
            }
        }
        .onAppear { focused = true }
        .onChange(of: openCount) {
            password = ""
            focused = true
        }
        // Whatever closes the panel (Escape, click outside, cleared session, hotkey) also drops the typed text.
        .onChange(of: closeCount) { password = "" }
        .onChange(of: attempts) {
            password = ""
            focused = true
        }
        .onChange(of: busy) {
            if !busy { focused = true }
        }
    }

    private func submit() {
        let submitted = password
        password = ""
        guard !submitted.isEmpty, !busy else { return }
        onSubmit(submitted)
    }
}

/// `bw` missing, too old or unsafe (designs 09, 16 state 1).
private struct SetupProblemView: View {
    let problem: SetupProblem
    let path: String?
    let copied: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelTitle(symbol: "exclamationmark.triangle", title: "VaultLight isn’t ready", tint: Theme.amber)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(problem.title)
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(problem.message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                if let command = problem.command {
                    commandBox(command).padding(.top, 14)
                }
                Text(problem.detail(path: path))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, bodyLeading)
            .padding(.trailing, 46)
            .padding(.top, 20)
            .padding(.bottom, 22)
            Divider()
            FooterBar(status: "Setup needed", dot: Theme.amber) {
                if problem.command != nil { KeyHint(key: "⌘C", label: "Copy command") }
                KeyHint(key: "⌘,", label: "Settings")
                KeyHint(key: "esc", label: "Close")
            }
        }
    }

    private func commandBox(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text("$").foregroundStyle(.tertiary)
            Text(command).textSelection(.enabled)
            Spacer()
            Button(action: onCopy) {
                HStack(spacing: 5) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                    Text(copied ? "Copied" : "Copy")
                }
                .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(SecondaryButtonStyle())
            .controlSize(.small)
            .accessibilityLabel(copied ? "Copied" : "Copy command")
        }
        .font(.system(size: 14, design: .monospaced))
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.wellFill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// A failed state check that isn't a setup problem (no design): fixed copy, Return retries.
private struct FailureView: View {
    let failure: PanelFailure

    var body: some View {
        VStack(spacing: 0) {
            PanelTitle(symbol: "exclamationmark.triangle", title: "VaultLight", tint: Theme.red)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.message).font(.system(size: 15, weight: .semibold))
                Text("Press Return to try again.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, bodyLeading)
            .padding(.vertical, 20)
            .accessibilityElement(children: .combine)
            Divider()
            FooterBar(status: "Error", dot: Theme.red) {
                KeyHint(key: "↵", label: "Try again")
                KeyHint(key: "esc", label: "Close")
            }
        }
    }
}

/// While the vault state is read: the header alone, so the panel doesn't jump much.
private struct CheckingView: View {
    var body: some View {
        VStack(spacing: 0) {
            PanelTitle(symbol: "lock", title: "VaultLight")
            Divider()
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 20)
        }
        .accessibilityLabel("Checking the vault")
    }
}
