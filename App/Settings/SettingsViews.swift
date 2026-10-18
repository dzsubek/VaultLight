import AppKit
import SwiftUI
import VaultLightCore

// MARK: General (design 14 states 1 and 4)

struct GeneralSettingsView: View {
    let model: AppModel

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Shortcut") {
                ShortcutRow(model: model)
            }
            SettingsSection(
                title: "Clipboard",
                footer: "Cleared only if the clipboard still holds the copied value. Usernames are not cleared."
            ) {
                SettingsRow(title: "Clear copied secrets after") {
                    OptionPicker(
                        selection: setting(\.clipboardTimeout), options: AppSettings.ClipboardTimeout.allCases,
                        label: { "\($0.rawValue) seconds" })
                }
            }
            SettingsSection(title: "Startup") {
                SettingsRow(title: "Launch at login") {
                    Toggle(
                        "Launch at login",
                        isOn: Binding(
                            get: { model.settings.settings.launchAtLogin }, set: { model.setLaunchAtLogin($0) })
                    )
                    .toggleStyle(.switch)
                    .tint(Theme.teal)
                    .labelsHidden()
                }
            }
        }
    }

    private func setting<Value>(_ path: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings.settings[keyPath: path] },
            set: { value in model.update { $0[keyPath: path] = value } })
    }
}

// MARK: Security (design 14 state 2)

struct SecuritySettingsView: View {
    let model: AppModel

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Touch ID") {
                SettingsRow(
                    title: "Stored session lasts", subtitle: "After this, the master password is required again."
                ) {
                    OptionPicker(
                        selection: setting(\.session.storedMaximumAge),
                        options: SessionSettings.StoredMaximumAge.allCases, label: \.label)
                }
                SettingsRow(title: "Require master password after restart", divider: true) {
                    Toggle(
                        "Require master password after restart",
                        isOn: setting(\.session.requireMasterPasswordAfterRestart)
                    )
                    .toggleStyle(.switch)
                    .tint(Theme.teal)
                    .labelsHidden()
                }
            }
            SettingsSection(title: "Auto-lock", footer: "VaultLight also locks on sleep, screen lock and user switch.")
            {
                SettingsRow(title: "Stay unlocked after Touch ID") {
                    OptionPicker(
                        selection: setting(\.session.inMemoryLifetime),
                        options: SessionSettings.InMemoryLifetime.allCases,
                        label: {
                            switch $0 {
                            case .fifteenMinutes: "15 minutes"
                            case .oneHour: "1 hour"
                            case .eightHours: "8 hours"
                            }
                        })
                }
                SettingsRow(title: "Lock after idle", divider: true) {
                    OptionPicker(
                        selection: setting(\.session.idleLock), options: SessionSettings.IdleLock.allCases,
                        label: {
                            switch $0 {
                            case .off: "Off"
                            case .fiveMinutes: "5 minutes"
                            case .fifteenMinutes: "15 minutes"
                            case .thirtyMinutes: "30 minutes"
                            }
                        })
                }
            }
        }
    }

    private func setting<Value>(_ path: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings.settings[keyPath: path] },
            set: { value in model.update { $0[keyPath: path] = value } })
    }
}

/// A pop-up of fixed options.
struct OptionPicker<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}

// MARK: Shortcut recorder (spec 4.1, design 14 states 1 and 4)

/// Click to record, Esc cancels, × resets to ⌘⇧Space. A shortcut the system refuses keeps the recorder recording
/// and says why in red.
private struct ShortcutRow: View {
    let model: AppModel

    @State private var recording = false
    @State private var refused: HotKeyShortcut?
    @State private var needsModifier = false
    @State private var monitor: Any?

    var body: some View {
        SettingsRow(title: "Open VaultLight", subtitle: subtitle, subtitleIsError: isError) {
            recorder
        }
        .onAppear {
            if model.shortcutUnavailable {
                refused = model.settings.settings.hotKey
                startRecording()
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var isError: Bool { refused != nil || needsModifier }

    private var subtitle: String {
        if let refused {
            return "\(refused.displayString) is already used by another app. Choose a different shortcut."
        }
        if needsModifier { return "Use ⌘, ⌥ or ⌃ with the key." }
        return "Works in every app, including full-screen ones."
    }

    private var recorder: some View {
        HStack(spacing: 6) {
            Text(recording ? "Press a shortcut…" : model.settings.settings.hotKey.displayString)
                .font(.system(size: 13.5))
                .foregroundStyle(recording ? .tertiary : .primary)
            Spacer(minLength: 4)
            Button {
                reset()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset to ⌘⇧Space")
        }
        .padding(.horizontal, 9)
        .frame(width: 176, height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fieldFill))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isError && recording ? Theme.red : recording ? Theme.teal : Theme.hairline,
                    lineWidth: recording ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { recording ? stopRecording() : startRecording() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shortcut, \(model.settings.settings.hotKey.displayString)")
        .accessibilityHint("Click, then press the new shortcut")
        .accessibilityAddTraits(.isButton)
    }

    private func startRecording() {
        stopRecording()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) } ? nil : event
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    /// Returns whether the event was taken.
    private func record(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, flags.isEmpty {
            stopRecording()
            needsModifier = false
            if !model.shortcutUnavailable { refused = nil }
            return true
        }
        let shortcut = HotKeyShortcut(
            keyCode: UInt32(event.keyCode), modifiers: Self.carbonFlags(flags), key: Self.label(for: event))
        guard shortcut.hasModifier else {
            needsModifier = true
            return true
        }
        needsModifier = false
        if model.setShortcut(shortcut) {
            refused = nil
            stopRecording()
        } else {
            refused = shortcut
        }
        return true
    }

    private func reset() {
        needsModifier = false
        if model.setShortcut(.default) {
            refused = nil
            stopRecording()
        } else {
            refused = .default
            startRecording()
        }
    }

    private static func carbonFlags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= HotKeyShortcut.command }
        if flags.contains(.shift) { result |= HotKeyShortcut.shift }
        if flags.contains(.option) { result |= HotKeyShortcut.option }
        if flags.contains(.control) { result |= HotKeyShortcut.control }
        return result
    }

    /// Key codes: 49 Space, 36 Return, 48 Tab, 51 Delete, 123–126 arrows, F-keys by code.
    private static func label(for event: NSEvent) -> String {
        let named: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = named[event.keyCode] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}
