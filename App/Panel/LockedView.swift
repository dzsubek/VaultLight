import SwiftUI
import VaultLightCore

/// Interim views for the states that aren't search (spec 3.1), before the designed screens
/// (designs 06, 07, 09, 16). Fixed copy only: never raw error text, never a typed password kept anywhere but the
/// field.
struct LockedView: View {
    let controller: PanelController

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: PanelMetrics.searchHeight)
            Divider()
            Text(bodyText)
                .font(.system(size: 14))
                .foregroundStyle(isFailure ? Theme.red : .secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity)
                .frame(height: PanelMetrics.lockedBodyHeight)
        }
    }

    @ViewBuilder private var header: some View {
        switch controller.content {
        case .masterPassword(_, let busy):
            MasterPasswordField(
                busy: busy, openCount: controller.openCount, closeCount: controller.closeCount,
                onSubmit: { password in Task { await controller.unlock(masterPassword: password) } })
        case .touchID:
            title(symbol: "touchid", text: "Touch ID to unlock")
        case .checking, .needsOnboarding, .problem, .unlocked:
            title(symbol: "lock", text: "VaultLight")
        }
    }

    private func title(symbol: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 22))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private var isFailure: Bool {
        if case .masterPassword(let failed, _) = controller.content { return failed }
        return false
    }

    private var bodyText: String {
        switch controller.content {
        case .checking, .unlocked: ""
        case .touchID(let canceled): canceled ? "Press Return to try again." : "Waiting for Touch ID…"
        case .masterPassword(let failed, let busy):
            failed ? "Wrong master password" : busy ? "Unlocking…" : "Enter your master password to unlock."
        case .needsOnboarding: "Sign in to Bitwarden first. Onboarding arrives in a later version."
        case .problem(let problem): problem.message
        }
    }
}

/// The master password field. The text exists only in the field's binding and is cleared as soon as it is
/// submitted.
private struct MasterPasswordField: View {
    let busy: Bool
    let openCount: Int
    let closeCount: Int
    let onSubmit: (String) -> Void

    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            SecureField("Master password", text: $password)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .tint(Theme.teal)
                .autocorrectionDisabled()
                .focused($focused)
                .disabled(busy)
                .accessibilityLabel("Master password")
                .onSubmit {
                    let submitted = password
                    password = ""
                    guard !submitted.isEmpty else { return }
                    onSubmit(submitted)
                }
        }
        .padding(.horizontal, 20)
        .onAppear { focused = true }
        .onChange(of: openCount) {
            password = ""
            focused = true
        }
        // Whatever closes the panel (Escape, click outside, cleared session, hotkey) also drops the typed text.
        .onChange(of: closeCount) { password = "" }
        .onChange(of: busy) {
            if !busy { focused = true }
        }
    }
}
