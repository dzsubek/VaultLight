import AppKit

/// The menu-bar item (spec 4).
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let openHandler: @MainActor () -> Void
    private let openItem: NSMenuItem

    init(onOpen: @escaping @MainActor () -> Void) {
        openHandler = onOpen
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
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
        setIcon(systemName: "key.horizontal", description: "VaultLight")
    }

    /// Hotkey registration failed (spec 4.1): warning icon, and the menu says why.
    func showShortcutUnavailable() {
        setIcon(systemName: "exclamationmark.triangle", description: "VaultLight, shortcut unavailable")
        let notice = NSMenuItem(title: "Shortcut ⌘⇧Space unavailable", action: nil, keyEquivalent: "")
        notice.isEnabled = false
        statusItem.menu?.insertItem(notice, at: 0)
        statusItem.menu?.insertItem(.separator(), at: 1)
    }

    private func setIcon(systemName: String, description: String) {
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityLabel(description)
    }

    @objc private func openPanel() {
        openHandler()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
