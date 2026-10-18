import AppKit
import Observation
import VaultLightCore

/// The menu-bar item (spec 4). Shows the clipboard countdown while
/// a copied secret is pending (spec 6.2, design 04).
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let clipboard: ClipboardManager
    private let openHandler: @MainActor () -> Void
    private let openItem: NSMenuItem
    private var symbolName = "key.horizontal"
    private var iconDescription = "VaultLight"

    init(clipboard: ClipboardManager, onOpen: @escaping @MainActor () -> Void) {
        self.clipboard = clipboard
        openHandler = onOpen
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        openItem = NSMenuItem(title: "Open VaultLight", action: #selector(openPanel), keyEquivalent: " ")
        super.init()

        openItem.keyEquivalentModifierMask = [.command, .shift]
        openItem.target = self

        let menu = NSMenu()
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit VaultLight", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        updateIcon()
        observeClipboard()
    }

    /// Hotkey registration failed (spec 4.1): warning icon, and the menu says why.
    func showShortcutUnavailable() {
        symbolName = "exclamationmark.triangle"
        iconDescription = "VaultLight, shortcut unavailable"
        updateIcon()
        let notice = NSMenuItem(title: "Shortcut ⌘⇧Space unavailable", action: nil, keyEquivalent: "")
        notice.isEnabled = false
        statusItem.menu?.insertItem(notice, at: 0)
        statusItem.menu?.insertItem(.separator(), at: 1)
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        if let seconds = clipboard.secondsUntilClear {
            button.image = MenuBarIcon.countdown(symbolName: symbolName, seconds: seconds)
            button.setAccessibilityLabel("\(iconDescription), clipboard clears in \(seconds) seconds")
        } else {
            button.image = MenuBarIcon.resting(symbolName: symbolName, description: iconDescription)
            button.setAccessibilityLabel(iconDescription)
        }
    }

    /// Redraws on every change of the countdown, for as long as this controller lives.
    private func observeClipboard() {
        withObservationTracking {
            _ = clipboard.secondsUntilClear
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateIcon()
                self?.observeClipboard()
            }
        }
    }

    @objc private func openPanel() {
        openHandler()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
