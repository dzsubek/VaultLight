import SwiftUI
import VaultLightCore

// MARK: Sign in (design 11 states 1 and 3, design 16 state 3)

struct SignInStepView: View {
    @Bindable var model: OnboardingModel
    let closeCount: Int

    private enum Field { case email, password, clientID, clientSecret }

    @State private var password = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var attempts = 0
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: String(localized: "Sign in to Bitwarden"),
                subtitle: model.method == .emailPassword
                    ? String(localized: "Use the email and master password of your Bitwarden account.")
                    : String(localized: "Use your personal API key. It works with every two-step method."))
            MethodPicker(method: $model.method).padding(.top, 14)
            if model.method == .emailPassword {
                labeled("Email") {
                    TextField("", text: $model.email)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .fieldBox(focused: focus == .email)
                        .accessibilityLabel("Email")
                        .onSubmit { focus = .password }
                }
                labeled("Master password") {
                    SecureField("", text: $password)
                        .focused($focus, equals: .password)
                        .fieldBox(focused: focus == .password, failed: model.failure != nil)
                        .accessibilityLabel("Master password")
                        .onSubmit(submit)
                }
            } else {
                labeled("client_id") {
                    TextField("", text: $clientID)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .clientID)
                        .fieldBox(focused: focus == .clientID, monospaced: true)
                        .accessibilityLabel("client_id")
                        .onSubmit { focus = .clientSecret }
                }
                labeled("client_secret") {
                    SecureField("", text: $clientSecret)
                        .focused($focus, equals: .clientSecret)
                        .fieldBox(focused: focus == .clientSecret, failed: model.failure != nil, monospaced: true)
                        .accessibilityLabel("client_secret")
                        .onSubmit(submit)
                }
            }
            if let failure = model.failure {
                ErrorLine(message: failure.message).padding(.top, 8)
            }
            Text(
                model.method == .emailPassword
                    ? "If your account uses a two-step method the CLI can’t complete, such as a security key or Duo, sign in with an API key instead."
                    : "Find both in the web vault under Settings → Security → Keys → View API key. The key is used for this sign-in only and is not stored."
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, 70)
            .padding(.top, 14)
            StepButtons(
                title: String(localized: "Sign in"), busy: model.isBusy, onBack: { Task { await model.back() } },
                onSubmit: submit)
        }
        .stepInsets()
        .shake(attempts)
        .onAppear { focus = firstField }
        .onChange(of: model.method) {
            model.clearFailure()
            focus = firstField
        }
        .onChange(of: model.failure) {
            guard model.failure != nil else { return }
            attempts += 1
            password = ""
            clientSecret = ""
            focus = model.method == .emailPassword ? .password : .clientSecret
        }
        .onChange(of: closeCount) { clearSecrets() }
    }

    /// Where typing starts: the email until one is entered, then the password; client_id for an API key.
    private var firstField: Field {
        switch model.method {
        case .emailPassword: model.email.isEmpty ? .email : .password
        case .apiKey: .clientID
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            content()
        }
        .padding(.top, 14)
    }

    private func submit() {
        guard !model.isBusy else { return }
        switch model.method {
        case .emailPassword:
            let submitted = password
            password = ""
            guard !submitted.isEmpty, !model.email.isEmpty else { return }
            Task { await model.signIn(password: submitted) }
        case .apiKey:
            let id = clientID
            let secret = clientSecret
            clearSecrets()
            guard !id.isEmpty, !secret.isEmpty else { return }
            Task { await model.signIn(clientID: id, clientSecret: secret) }
        }
    }

    private func clearSecrets() {
        password = ""
        clientID = ""
        clientSecret = ""
    }
}

/// "Email and password" | "API key" (⌘1 / ⌘2).
private struct MethodPicker: View {
    @Binding var method: OnboardingModel.Method

    var body: some View {
        HStack(spacing: 2) {
            segment(String(localized: "Email and password"), .emailPassword)
            segment(String(localized: "API key"), .apiKey)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chipFill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sign-in method")
    }

    private func segment(_ title: String, _ value: OnboardingModel.Method) -> some View {
        let selected = method == value
        return Text(title)
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Theme.fieldFill : .clear)
                    .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1, y: 0.5)
            )
            .contentShape(Rectangle())
            .onTapGesture { method = value }
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { method = value }
    }
}

/// Back and the primary button, right-aligned.
struct StepButtons: View {
    let title: String
    let busy: Bool
    let onBack: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Back", action: onBack).buttonStyle(SecondaryButtonStyle()).disabled(busy)
            Button(action: onSubmit) { ReturnLabel(title: title, busy: busy) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy)
        }
        .padding(.top, 14)
    }
}

// MARK: Two-step code (design 11 state 2, design 16 state 4)

struct TwoFactorStepView: View {
    let model: OnboardingModel
    let closeCount: Int

    @State private var code = ""
    @State private var attempts = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(title: String(localized: "Two-step login"), subtitle: subtitle)
            CodeBoxes(code: $code, focused: $focused, failed: model.failure != nil, onComplete: verify)
                .padding(.top, 14)
            if let failure = model.failure {
                ErrorLine(message: failure.message).padding(.top, 10)
            }
            if model.twoFactorMethod != .email {
                HStack(spacing: 4) {
                    Text("No access to the app?").foregroundStyle(.secondary)
                    Button("Send a code by email") { Task { await model.sendCodeByEmail() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.teal)
                        .disabled(model.isBusy)
                }
                .font(.system(size: 13))
                .padding(.top, 14)
            }
            StepButtons(
                title: String(localized: "Verify"), busy: model.isBusy, onBack: { Task { await model.back() } },
                onSubmit: verify)
        }
        .stepInsets()
        .shake(attempts)
        .onAppear { focused = true }
        .onChange(of: model.failure) {
            guard model.failure != nil else { return }
            attempts += 1
            code = ""
            focused = true
        }
        .onChange(of: model.twoFactorMethod) {
            code = ""
            focused = true
        }
        .onChange(of: closeCount) { code = "" }
    }

    private var subtitle: String {
        let email = model.email
        switch (model.twoFactorMethod, email.isEmpty) {
        case (.email, true): return String(localized: "Enter the 6-digit code from the email Bitwarden sent.")
        case (.email, false):
            return String(localized: "Enter the 6-digit code from the email Bitwarden sent for \(email).")
        case (.authenticator, true): return String(localized: "Enter the 6-digit code from your authenticator app.")
        case (.authenticator, false):
            return String(localized: "Enter the 6-digit code from your authenticator app for \(email).")
        // The account's only method: `bw` doesn't say which, and has already emailed the code if it is email.
        case (nil, true):
            return String(
                localized: "Enter the 6-digit code from your authenticator app, or from the email Bitwarden sent.")
        case (nil, false):
            return String(
                localized:
                    "Enter the 6-digit code from your authenticator app, or from the email Bitwarden sent for \(email)."
            )
        }
    }

    private func verify() {
        let submitted = code
        guard submitted.count == 6, !model.isBusy else { return }
        Task { await model.verify(code: submitted) }
    }
}

/// Six boxes over one hidden field: digits fill the boxes in turn, a paste fills all six, the sixth submits.
private struct CodeBoxes: View {
    @Binding var code: String
    var focused: FocusState<Bool>.Binding
    let failed: Bool
    let onComplete: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            TextField("", text: $code)
                .textFieldStyle(.plain)
                .foregroundStyle(.clear)
                .tint(.clear)
                .focused(focused)
                .frame(width: 320, height: 54)
                .opacity(0.02)
                .accessibilityLabel("Two-step code")
                .onChange(of: code) {
                    let digits = String(code.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    if digits != code { code = digits }
                    if digits.count == 6 { onComplete() }
                }
            HStack(spacing: 9) {
                ForEach(0..<6, id: \.self) { index in box(index) }
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = true }
    }

    private func box(_ index: Int) -> some View {
        let characters = Array(code)
        let isCurrent = focused.wrappedValue && index == min(characters.count, 5)
        return ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.fieldFill)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    Theme.border(failed: failed, active: isCurrent),
                    lineWidth: Theme.borderWidth(failed: failed, active: isCurrent))
            if index < characters.count {
                Text(String(characters[index])).font(.system(size: 22))
            } else if isCurrent {
                Rectangle().fill(Theme.teal).frame(width: 1.5, height: 24)
            }
        }
        .frame(width: 46, height: 54)
        .shadow(color: Theme.teal.opacity(isCurrent ? 0.18 : 0), radius: 3)
    }
}

// MARK: Unlock (design 12 state 1)

struct UnlockStepView: View {
    let model: OnboardingModel
    let maximumAge: SessionSettings.StoredMaximumAge
    let closeCount: Int
    let onSubmit: (String) -> Void

    @State private var password = ""
    @State private var attempts = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(title: String(localized: "Unlock your vault"), subtitle: subtitle)
            VStack(alignment: .leading, spacing: 6) {
                Text("Master password").font(.system(size: 13)).foregroundStyle(.secondary)
                SecureField("", text: $password)
                    .focused($focused)
                    .fieldBox(focused: focused, failed: model.failure != nil)
                    .accessibilityLabel("Master password")
                    .onSubmit(submit)
            }
            .padding(.top, 14)
            if let failure = model.failure {
                ErrorLine(message: failure.message).padding(.top, 8)
            }
            Text(
                "After this, Touch ID unlocks VaultLight for up to \(maximumAge.label). The master password is never stored."
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)
            StepButtons(
                title: String(localized: "Unlock"), busy: model.isBusy, onBack: { Task { await model.back() } },
                onSubmit: submit)
        }
        .stepInsets()
        .shake(attempts)
        .onAppear { focused = true }
        .onChange(of: model.failure) {
            guard model.failure != nil else { return }
            attempts += 1
            password = ""
            focused = true
        }
        .onChange(of: closeCount) { password = "" }
    }

    private var subtitle: String {
        // Two sentences, each translated on its own.
        let account =
            model.signedInEmail.map { String(localized: "Signed in as \($0).") } ?? String(localized: "Signed in.")
        let request =
            model.method == .apiKey
            ? String(localized: "An API-key sign-in doesn’t unlock the vault, so enter your master password once.")
            : String(localized: "Enter your master password once more to unlock the vault.")
        return "\(account) \(request)"
    }

    private func submit() {
        let submitted = password
        password = ""
        guard !submitted.isEmpty, !model.isBusy else { return }
        onSubmit(submitted)
    }
}
