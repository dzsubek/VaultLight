import AppKit
import VaultLightCore

/// Keyboard handling per screen (spec 5.4, NOTES.md screens 6–12). The search field never loses focus, so search keys
/// are taken here; the other screens let their fields have Return, Tab and typing.
extension PanelController {
    func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return handled ? nil : event
        }
    }

    func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Copies a setup screen's Homebrew command (design 09). Not a secret, but written like every other copy
    /// (current host only, concealed), and never cleared on a timer.
    func copySetupCommand() {
        guard case .setupProblem(let problem) = content, let command = problem.command else { return }
        do {
            try clipboard.copyUsername(command)
            markCommandCopied()
        } catch {
            Self.logger.error("Copying the command failed")
        }
    }

    /// Returns whether the event was consumed.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        // An input method composing text owns Return, arrows and Escape.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([
            .numericPad, .function,
        ])
        let character = event.charactersIgnoringModifiers?.lowercased()
        if modifiers.isEmpty, event.keyCode == 53 {
            close()
            return true
        }
        switch content {
        case .unlocked:
            guard let key = Self.key(for: event) else { return Self.isTab(event) }  // Tab does nothing
            Task { await perform(key) }
            return true
        case .onboarding:
            return handleOnboardingKey(event, modifiers: modifiers, character: character)
        default:
            break
        }
        return handleLockedKey(event, modifiers: modifiers, character: character)
    }

    /// Touch ID, master password, setup problem and failure screens.
    private func handleLockedKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags, character: String?) -> Bool {
        if modifiers == .command, character == "," {
            openSettings()
            return true
        }
        let isReturn = modifiers.isEmpty && (event.keyCode == 36 || event.keyCode == 76)
        switch content {
        case .touchID where isReturn:
            Task { await unlockWithTouchID() }
            return true
        case .failure where isReturn:
            Task { await refreshLockedState() }
            return true
        case .setupProblem where modifiers == .command && character == "c":
            copySetupCommand()
            return true
        default:
            // The master password field owns Return.
            return false
        }
    }

    /// ⌘[ Back, ⌘1 / ⌘2 sign-in method, ↑/↓ and Return on the server list (design 10, 11).
    private func handleOnboardingKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags, character: String?) -> Bool {
        if modifiers == .command {
            switch character {
            case "[":
                Task { await onboarding.back() }
                return true
            case "1" where onboarding.step == .signIn:
                onboarding.method = .emailPassword
                return true
            case "2" where onboarding.step == .signIn:
                onboarding.method = .apiKey
                return true
            default:
                return false
            }
        }
        guard modifiers.isEmpty, onboarding.step == .server else { return false }
        let options = OnboardingModel.ServerOption.allCases
        let current = options.firstIndex(of: onboarding.serverOption) ?? 0
        switch event.keyCode {
        case 126:
            onboarding.serverOption = options[max(current - 1, 0)]
            onboarding.clearFailure()
            return true
        case 125:
            onboarding.serverOption = options[min(current + 1, options.count - 1)]
            onboarding.clearFailure()
            return true
        case 36, 76:
            Task { await onboarding.continueFromServer() }
            return true
        default:
            return false
        }
    }

    private static func isTab(_ event: NSEvent) -> Bool {
        event.keyCode == 48 && event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask)
    }

    /// Key codes: 126 up, 125 down, 36 Return, 76 keypad Enter, 53 Escape.
    static func key(for event: NSEvent) -> PanelKey? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        if modifiers.isEmpty { return plainKey(keyCode: event.keyCode) }
        guard modifiers == .command, let character = event.charactersIgnoringModifiers?.lowercased() else {
            return nil
        }
        return commandKey(character)
    }

    private static func plainKey(keyCode: UInt16) -> PanelKey? {
        switch keyCode {
        case 126: .up
        case 125: .down
        case 36, 76: .returnKey
        case 53: .escape
        default: nil
        }
    }

    private static func commandKey(_ character: String) -> PanelKey? {
        switch character {
        case "p": .copyPassword
        case "u": .copyUsername
        case "t": .copyTOTP
        case "o": .openURL
        case ",": .openSettings
        default: nil
        }
    }
}
