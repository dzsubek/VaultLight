#if DEBUG
    import AppKit
    import SwiftUI
    import VaultLightCore

    /// DEBUG-only screenshot mode: `-VLScreenshotDir <absolute dir>`. Drives the real panel controller, panel and
    /// view model against an in-memory demo vault of invented entries and writes PNGs. No `SessionManager`, no `bw`,
    /// no Keychain, no real vault content.
    @MainActor
    enum DemoScreens {
        static func requestedDirectory() -> URL? {
            let arguments = CommandLine.arguments
            guard let flag = arguments.firstIndex(of: "-VLScreenshotDir"), flag + 1 < arguments.count,
                arguments[flag + 1].hasPrefix("/")
            else { return nil }
            return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        }

        /// Panel screens, by design file name.
        private enum Screen: String, CaseIterable {
            case empty = "01-search-empty"
            case results = "02-search-results"
            case usernameCopied = "03-username-copied"
            case passwordCopied = "04-password-copied"
            case noResults = "05-no-results"
            case touchID = "06-locked-touchid"
            case masterPassword = "07-locked-master-password"
            case wrongPassword = "07-locked-wrong-password"
            case bwMissing = "09-bw-missing"
            case server = "10-onboarding-server"
            case serverSelfHosted = "10-onboarding-server-selfhosted"
            case signInEmail = "11-onboarding-signin-email"
            case signIn2FA = "11-onboarding-signin-2fa"
            case signInAPIKey = "11-onboarding-signin-apikey"
            case unlock = "12-onboarding-unlock"
            case finishing = "12-onboarding-finishing"
            case bwTooOld = "16-error-bw-too-old"
            case serverUnreachable = "16-error-server-unreachable"
            case signInError = "16-error-signin"
            case codeError = "16-error-2fa-code"
        }

        nonisolated static let demoEmail = "marta.keller@fastmail.com"

        static func run(into directory: URL) async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let appearances: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
            for (name, suffix) in appearances {
                let appearance = NSAppearance(named: name)
                NSApp.appearance = appearance
                func save(_ data: Data?, _ file: String) {
                    try? data?.write(to: directory.appending(path: "\(file)-\(suffix).png"))
                }
                for screen in Screen.allCases {
                    // A fresh vault and controller per image, so one screen's copies never change another's ranking.
                    // The real clipboard manager over an in-memory pasteboard: the countdown is real, `.general` untouched.
                    let controller = PanelController(
                        vault: DemoVault(), clipboard: ClipboardManager(pasteboard: DemoPasteboard()), session: nil,
                        onboarding: OnboardingModel(backend: backend(for: screen)), openURL: { _ in },
                        opaqueBackground: opaque)
                    controller.panel.appearance = appearance
                    await drive(controller, to: screen)
                    try? await Task.sleep(for: .milliseconds(500))
                    save(png(of: controller.panel), screen.rawValue)
                    controller.close()
                }
                save(png(of: menuBarStrip(appearance: appearance)), "04-password-copied-menubar")
                save(png(of: footerStates(appearance: appearance)), "16-error-footer")
                for (state, file) in menuStates {
                    let model = demoModel()
                    state(model)
                    save(png(of: menuSnapshot(model: model, appearance: appearance)), file)
                }
                for state in settingsStates {
                    let model = demoModel()
                    model.setDemoState(
                        .unlocked, summary: unlockedSummary, shortcutUnavailable: state.conflict,
                        lastSyncedAt: Date().addingTimeInterval(-180), bwInUse: ("/opt/homebrew/bin/bw", "2025.9.0"))
                    let window = SettingsWindowController(model: model)
                    window.window?.appearance = appearance
                    window.select(state.tab)
                    window.window?.orderFront(nil)
                    try? await Task.sleep(for: .milliseconds(600))
                    save(window.window.flatMap(png(ofWindow:)), state.file)
                    window.close()
                }
                let model = demoModel()
                model.setDemoState(.unlocked, summary: unlockedSummary, bwInUse: ("/opt/homebrew/bin/bw", "2025.9.0"))
                let about = AboutWindowController(model: model)
                about.window?.appearance = appearance
                about.window?.orderFront(nil)
                try? await Task.sleep(for: .milliseconds(500))
                save(about.window.flatMap(png(ofWindow:)), "15-about")
                about.close()
            }
        }

        private static let unlockedSummary = VaultSummary(
            isUnlocked: true, email: demoEmail, serverURL: "https://vault.bitwarden.com", loginCount: 214)

        /// An `AppModel` over its own defaults suite; nothing in it starts `bw` or reads the Keychain.
        private static func demoModel() -> AppModel {
            let defaults = UserDefaults(suiteName: "com.vaultlight.demo.\(UUID().uuidString)") ?? .standard
            let model = AppModel(
                clipboard: ClipboardManager(pasteboard: DemoPasteboard()), settings: SettingsStore(defaults: defaults))
            model.isLive = false
            return model
        }

        private static let menuStates: [(@MainActor (AppModel) -> Void, String)] = [
            ({ $0.setDemoState(.unlocked, summary: unlockedSummary) }, "13-menubar-menu-unlocked"),
            (
                {
                    $0.setDemoState(
                        .storedSessionAvailable,
                        summary: VaultSummary(storedSessionExpiresAt: Date().addingTimeInterval(6 * 86_400 + 3_600)))
                }, "13-menubar-menu-locked"
            ),
            (
                { $0.setDemoState(.unlocked, summary: unlockedSummary, shortcutUnavailable: true) },
                "13-menubar-menu-shortcut-unavailable"
            ),
        ]

        private struct SettingsState {
            let tab: SettingsTab
            let conflict: Bool
            let file: String
        }

        private static let settingsStates = [
            SettingsState(tab: .general, conflict: false, file: "14-settings-general"),
            SettingsState(tab: .security, conflict: false, file: "14-settings-security"),
            SettingsState(tab: .vault, conflict: false, file: "14-settings-vault"),
            SettingsState(tab: .general, conflict: true, file: "14-settings-shortcut-conflict"),
        ]

        private static func backend(for screen: Screen) -> DemoOnboardingBackend {
            switch screen {
            case .serverUnreachable: DemoOnboardingBackend(login: .offline)
            case .signInError: DemoOnboardingBackend(login: .wrongPassword)
            case .signIn2FA, .codeError: DemoOnboardingBackend(login: .twoFactor)
            case .finishing: DemoOnboardingBackend(unlockHangs: true)
            default: DemoOnboardingBackend()
            }
        }

        /// Set to `true` when the translucent material doesn't survive `cacheDisplay`.
        static let opaque = true

        // swiftlint:disable:next cyclomatic_complexity function_body_length
        private static func drive(_ controller: PanelController, to screen: Screen) async {
            let onboarding = controller.onboarding
            switch screen {
            case .empty:
                // Real copies through the view model, oldest first, so the list shows "Recent", newest first.
                for name in ["Figma", "Hetzner Cloud", "Linear", "AWS Console", "Fastmail", "GitHub"] {
                    await controller.viewModel.setQuery(name)
                    await controller.perform(.copyUsername)
                }
                await controller.open()
            case .results:
                await search(controller, for: "git")
                await controller.perform(.down)
            case .usernameCopied:
                await search(controller, for: "git")
                await controller.perform(.down)
                await controller.perform(.copyUsername)
            case .passwordCopied:
                await search(controller, for: "git")
                await controller.perform(.down)
                // Through the view model, not `perform`, so the panel stays on screen for the capture.
                _ = await controller.viewModel.handle(.returnKey)
            case .noResults:
                await search(controller, for: "kubernetes")
            case .touchID:
                await show(
                    controller, .touchID(canceled: false),
                    summary: VaultSummary(
                        email: demoEmail, storedSessionExpiresAt: Date().addingTimeInterval(6 * 86_400 + 3_600)))
            case .masterPassword:
                await show(
                    controller, .masterPassword(.restarted, attempts: 0, busy: false),
                    summary: VaultSummary(email: demoEmail))
                await type("demo-password", into: controller)
            case .wrongPassword:
                await show(
                    controller, .masterPassword(.restarted, attempts: 1, busy: false),
                    summary: VaultSummary(email: demoEmail))
            case .bwMissing:
                await show(controller, .setupProblem(.notInstalled))
            case .bwTooOld:
                await show(controller, .setupProblem(.tooOld(installed: "2024.6.1")), setupPath: "/opt/homebrew/bin/bw")
            case .server:
                await show(controller, .onboarding)
            case .serverSelfHosted, .serverUnreachable:
                onboarding.serverOption = .selfHosted
                onboarding.selfHostedAddress = "https://vault.home.arpa"
                await show(controller, .onboarding)
                if screen == .serverUnreachable {
                    await onboarding.continueFromServer()
                    onboarding.email = demoEmail
                    await onboarding.signIn(password: "demo-password")
                }
            case .signInEmail, .signInError, .signIn2FA, .codeError:
                await atSignIn(controller)
                if screen == .signInEmail {
                    await type("demo-password", into: controller)
                } else {
                    await onboarding.signIn(password: "demo-password")
                }
                if screen == .signIn2FA {
                    try? await Task.sleep(for: .milliseconds(300))
                    await type("482", into: controller)
                }
                if screen == .codeError {
                    await onboarding.verify(code: "000000")
                }
            case .signInAPIKey:
                await atSignIn(controller)
                onboarding.method = .apiKey
                try? await Task.sleep(for: .milliseconds(300))
                await type("user.7c1e4b9a-02f3-4d8e-b5a1-63e0f2c4d917", into: controller)
            case .unlock, .finishing:
                await atSignIn(controller)
                onboarding.method = .apiKey
                await onboarding.signIn(clientID: "user.demo", clientSecret: "demo-secret")
                if screen == .unlock {
                    try? await Task.sleep(for: .milliseconds(300))
                    await type("demo-password", into: controller)
                } else {
                    Task { await controller.finishOnboarding(masterPassword: "demo-password") }
                }
            }
        }

        private static func show(
            _ controller: PanelController, _ content: PanelContent, summary: VaultSummary = VaultSummary(),
            setupPath: String? = nil
        ) async {
            await controller.open()
            controller.showDemo(content, summary: summary, setupPath: setupPath)
            try? await Task.sleep(for: .milliseconds(300))
        }

        private static func atSignIn(_ controller: PanelController) async {
            await show(controller, .onboarding)
            await controller.onboarding.continueFromServer()
            controller.onboarding.email = demoEmail
            try? await Task.sleep(for: .milliseconds(300))
        }

        /// Types invented text into the focused field, as the keyboard would.
        private static func type(_ text: String, into controller: PanelController) async {
            var editor = controller.panel.firstResponder as? NSTextView
            if editor == nil, let field = textFields(in: controller.panel.contentView).first {
                controller.panel.makeFirstResponder(field)
                editor = field.currentEditor() as? NSTextView
            }
            editor?.insertText(text, replacementRange: editor?.selectedRange() ?? NSRange())
            try? await Task.sleep(for: .milliseconds(200))
        }

        private static func textFields(in view: NSView?) -> [NSTextField] {
            guard let view else { return [] }
            if let field = view as? NSTextField, field.isEditable { return [field] }
            return view.subviews.flatMap(textFields(in:))
        }

        private static func search(_ controller: PanelController, for query: String) async {
            await controller.open()
            controller.queryText = query
            await controller.submitQuery()
        }

    }
#endif
