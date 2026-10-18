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
                        selection: model.settingBinding(\.clipboardTimeout),
                        options: AppSettings.ClipboardTimeout.allCases, label: \.label)
                }
            }
            SettingsSection(title: "Startup") {
                SettingsRow(title: "Launch at login") {
                    SettingsSwitch(
                        title: "Launch at login",
                        isOn: Binding(
                            get: { model.settings.settings.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                }
            }
        }
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
                        selection: model.settingBinding(\.session.storedMaximumAge),
                        options: SessionSettings.StoredMaximumAge.allCases, label: \.label)
                }
                SettingsRow(title: "Require master password after restart", divider: true) {
                    SettingsSwitch(
                        title: "Require master password after restart",
                        isOn: model.settingBinding(\.session.requireMasterPasswordAfterRestart))
                }
            }
            SettingsSection(title: "Auto-lock", footer: "VaultLight also locks on sleep, screen lock and user switch.")
            {
                SettingsRow(title: "Stay unlocked after Touch ID") {
                    OptionPicker(
                        selection: model.settingBinding(\.session.inMemoryLifetime),
                        options: SessionSettings.InMemoryLifetime.allCases, label: \.label)
                }
                SettingsRow(title: "Lock after idle", divider: true) {
                    OptionPicker(
                        selection: model.settingBinding(\.session.idleLock),
                        options: SessionSettings.IdleLock.allCases, label: \.label)
                }
            }
        }
    }
}

extension AppModel {
    /// A binding to one setting; writes go through `update`, so they apply at once.
    func settingBinding<Value>(_ path: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings.settings[keyPath: path] },
            set: { value in self.update { $0[keyPath: path] = value } })
    }
}

/// An on/off switch in a row; the row's title is its label.
struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .tint(Theme.teal)
            .labelsHidden()
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
                    Theme.border(failed: isError && recording, active: recording),
                    lineWidth: Theme.borderWidth(failed: isError && recording, active: recording))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleRecording)
        // Full Keyboard Access: Tab reaches the recorder, Space or Return starts recording.
        .focusable()
        .onKeyPress(keys: [.space, .return]) { _ in
            toggleRecording()
            return .handled
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shortcut, \(model.settings.settings.hotKey.displayString)")
        .accessibilityHint("Press, then press the new shortcut")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggleRecording() }
    }

    private func toggleRecording() {
        if recording {
            stopRecording()
        } else {
            startRecording()
        }
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
            keyCode: UInt32(event.keyCode), modifiers: HotKeyShortcut.carbonModifiers(flags),
            key: Self.label(for: event))
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
