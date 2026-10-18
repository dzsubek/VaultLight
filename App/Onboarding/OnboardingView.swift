import SwiftUI
import VaultLightCore

/// Onboarding in the panel (spec 3.2, designs 10–12 and 16): "Set up VaultLight" with the Server → Sign in → Unlock
/// indicator, one step's body, and the footer. The model holds the steps; the views hold typed secrets only in their
/// fields, which are cleared on submit, on a failure and when the panel closes.
struct OnboardingView: View {
    let controller: PanelController

    private var model: OnboardingModel { controller.onboarding }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.step {
                case .server: ServerStepView(model: model)
                case .signIn: SignInStepView(model: model, closeCount: controller.closeCount)
                case .twoFactor: TwoFactorStepView(model: model, closeCount: controller.closeCount)
                case .unlock:
                    UnlockStepView(
                        model: model, maximumAge: controller.storedMaximumAge, closeCount: controller.closeCount,
                        onSubmit: { password in Task { await controller.finishOnboarding(masterPassword: password) } })
                case .finishing: FinishingStepView(model: model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            FooterBar(status: footerStatus) {
                if canGoBack { KeyHint(key: "⌘[", label: "Back") }
                KeyHint(key: "esc", label: "Close")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppMark(size: 30)
            Text("Set up VaultLight")
                .font(.system(size: 18, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            StepIndicator(current: stepIndex)
        }
        .padding(.horizontal, 20)
        .frame(height: PanelMetrics.searchHeight)
    }

    private var stepIndex: Int {
        switch model.step {
        case .server: 0
        case .signIn, .twoFactor: 1
        case .unlock, .finishing: 2
        }
    }

    private var canGoBack: Bool {
        [.signIn, .twoFactor, .unlock].contains(model.step)
    }

    private var footerStatus: String {
        let server = model.configuredServer?.displayName ?? model.chosenServer.displayName
        switch model.step {
        case .server: return "Not signed in"
        case .signIn: return "\(server) · not signed in"
        case .twoFactor: return model.emailCodeSent ? "Code sent by email" : "\(server) · not signed in"
        case .unlock: return "Signed in · locked"
        case .finishing: return "Setting up…"
        }
    }
}

/// The placeholder app mark (design 10 header, design 15): a teal rounded square with a ring. Not Bitwarden's logo
/// (spec 11.5).
struct AppMark: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Theme.teal)
            .frame(width: size, height: size)
            .overlay(
                Circle().strokeBorder(.white, lineWidth: size * 0.075).frame(width: size * 0.46, height: size * 0.46)
            )
            .accessibilityHidden(true)
    }
}

/// ① Server ② Sign in ③ Unlock: done steps get a check, the current one is filled.
private struct StepIndicator: View {
    let current: Int
    private let titles = ["Server", "Sign in", "Unlock"]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 6) {
                    ZStack {
                        if index <= current {
                            Circle().fill(Theme.teal)
                        } else {
                            Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                        }
                        if index < current {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(index == current ? .white : .secondary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(title)
                        .font(.system(size: 13, weight: index == current ? .semibold : .regular))
                        .foregroundStyle(index == current ? .primary : .secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of 3, \(titles[current])")
    }
}

/// The title and the gray line under it, shared by the steps.
struct StepHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Step bodies share the same insets (designs 10–12).
extension View {
    func stepInsets() -> some View {
        padding(.horizontal, 25).padding(.top, 20).padding(.bottom, 20)
    }
}

// MARK: Server (design 10)

private struct ServerStepView: View {
    @Bindable var model: OnboardingModel
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "Choose your server",
                subtitle: "VaultLight signs in through the Bitwarden CLI. Pick where your account lives."
            )
            .padding(.horizontal, 25)
            VStack(spacing: 2) {
                row(.bitwardenUS, title: "Bitwarden US", subtitle: "vault.bitwarden.com · default")
                row(.bitwardenEU, title: "Bitwarden EU", subtitle: "vault.bitwarden.eu")
                row(.selfHosted, title: "Self-hosted", subtitle: "Vaultwarden or a Bitwarden server you run")
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            if let failure = model.failure, model.serverOption != .selfHosted {
                ErrorLine(message: failure.message).padding(.horizontal, 25).padding(.top, 6)
            }
            HStack {
                Spacer()
                Button {
                    Task { await model.continueFromServer() }
                } label: {
                    ReturnLabel(title: "Continue", busy: model.isBusy)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isBusy)
            }
            .padding(.horizontal, 25)
            .padding(.top, 14)
        }
        .padding(.top, 20)
        .padding(.bottom, 20)
        .onChange(of: model.serverOption) {
            addressFocused = model.serverOption == .selfHosted
        }
        .onAppear { addressFocused = model.serverOption == .selfHosted }
    }

    private func row(_ option: OnboardingModel.ServerOption, title: String, subtitle: String) -> some View {
        let selected = model.serverOption == option
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Radio(selected: selected).padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .medium))
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if selected, option == .selfHosted {
                TextField("https://vault.example.com", text: $model.selfHostedAddress)
                    .autocorrectionDisabled()
                    .focused($addressFocused)
                    .fieldBox(focused: addressFocused, failed: model.failure != nil, monospaced: true)
                    .padding(.leading, 30)
                    .padding(.top, 10)
                    .accessibilityLabel("Server address")
                    .onChange(of: model.selfHostedAddress) { model.clearFailure() }
                    .onSubmit { Task { await model.continueFromServer() } }
                if let failure = model.failure {
                    ErrorLine(message: failure.message).padding(.leading, 30).padding(.top, 6)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.tintedRowFill : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.serverOption = option
            model.clearFailure()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(title)
    }
}

private struct Radio: View {
    let selected: Bool

    var body: some View {
        ZStack {
            Circle().fill(Theme.fieldFill)
            Circle().strokeBorder(selected ? Theme.teal : Theme.hairline, lineWidth: selected ? 5 : 1)
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
