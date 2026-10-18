import AppKit
import Observation
import SwiftUI
import VaultLightCore

/// The menu-bar item and its menu (spec 8, design 13). Shows the clipboard countdown while a copied secret is
/// pending (spec 6.2, design 04), and an amber badge when the shortcut couldn't be registered (spec 4.1).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private let showAbout: @MainActor () -> Void
    private static let symbolName = "key.horizontal"

    init(model: AppModel, showAbout: @escaping @MainActor () -> Void) {
        self.model = model
        self.showAbout = showAbout
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuild(menu)
        updateIcon()
        observeModel()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
        // The status line reads what is known; refresh it for the next open without starting a process.
        Task { await model.refreshSummary() }
    }

    /// The items for the current state. Also used by the DEBUG screenshots.
    func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in Self.items(model: model, target: self) { menu.addItem(item) }
    }

    static func items(model: AppModel, target: StatusItemController?) -> [NSMenuItem] {
        let status = MenuStatus(state: model.lastState, summary: model.summary, now: Date())
        let shortcut = model.settings.settings.hotKey
        var items: [NSMenuItem] = []
        if model.shortcutUnavailable {
            items.append(
                header(
                    title: "Shortcut unavailable",
                    detail: "\(shortcut.displayString) is already used by another app", warning: true))
            items.append(item("Choose Another Shortcut…", #selector(chooseShortcut), target: target))
        } else {
            items.append(header(title: status.title, detail: status.detail, warning: false))
        }
        items.append(.separator())
        let open = item("Open VaultLight", #selector(openPanel), target: target)
        if !model.shortcutUnavailable {
            open.keyEquivalent = shortcut.key == "Space" ? " " : shortcut.key.lowercased()
            open.keyEquivalentModifierMask = modifierFlags(shortcut)
        }
        items.append(open)
        items.append(.separator())
        items.append(item("Sync Now", #selector(syncNow), target: target, enabled: status.canSync && !model.isSyncing))
        items.append(item("Lock Now", #selector(lockNow), target: target, enabled: status.canLock))
        items.append(
            item(
                "Lock and Forget…", #selector(lockAndForget), target: target,
                enabled: model.lastState != .needsOnboarding))
        items.append(.separator())
        let settings = item("Settings…", #selector(openSettings), target: target)
        settings.keyEquivalent = ","
        items.append(settings)
        items.append(item("About VaultLight", #selector(openAbout), target: target))
        items.append(.separator())
        let quit = item("Quit VaultLight", #selector(quit), target: target)
        quit.keyEquivalent = "q"
        items.append(quit)
        return items
    }

    private static func item(_ title: String, _ action: Selector, target: AnyObject?, enabled: Bool = true)
        -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.isEnabled = enabled
        return item
    }

    /// The first line: state in bold, detail in gray (design 13). It can't be clicked.
    private static func header(title: String, detail: String?, warning: Bool) -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSHostingView(rootView: MenuHeader(title: title, detail: detail, warning: warning))
        view.frame.size = view.fittingSize
        view.frame.size.width = max(view.frame.width, 280)
        item.view = view
        item.isEnabled = false
        item.setAccessibilityLabel([title, detail].compactMap(\.self).joined(separator: ", "))
        return item
    }

    private static func modifierFlags(_ shortcut: HotKeyShortcut) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers & HotKeyShortcut.command != 0 { flags.insert(.command) }
        if shortcut.modifiers & HotKeyShortcut.shift != 0 { flags.insert(.shift) }
        if shortcut.modifiers & HotKeyShortcut.option != 0 { flags.insert(.option) }
        if shortcut.modifiers & HotKeyShortcut.control != 0 { flags.insert(.control) }
        return flags
    }

    // MARK: Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let description = model.shortcutUnavailable ? "VaultLight, shortcut unavailable" : "VaultLight"
        if let seconds = model.clipboard.secondsUntilClear {
            button.image = MenuBarIcon.countdown(symbolName: Self.symbolName, seconds: seconds)
            button.setAccessibilityLabel("\(description), clipboard clears in \(seconds) seconds")
        } else if model.shortcutUnavailable {
            button.image = MenuBarIcon.badged(symbolName: Self.symbolName, description: description)
            button.setAccessibilityLabel(description)
        } else {
            button.image = MenuBarIcon.resting(symbolName: Self.symbolName, description: description)
            button.setAccessibilityLabel(description)
        }
    }

    /// Redraws on every change of the countdown or the shortcut state, for as long as this controller lives.
    private func observeModel() {
        withObservationTracking {
            _ = model.clipboard.secondsUntilClear
            _ = model.shortcutUnavailable
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateIcon()
                self?.observeModel()
            }
        }
    }

    // MARK: Actions

    @objc private func openPanel() {
        model.panel.toggle()
    }

    @objc private func chooseShortcut() {
        model.showSettings?(.general)
    }

    @objc private func syncNow() {
        Task { await model.syncNow() }
    }

    @objc private func lockNow() {
        model.lockNow()
    }

    /// Asks first: it deletes the stored session.
    @objc private func lockAndForget() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Lock and forget?"
        alert.informativeText =
            "VaultLight locks the vault and deletes the stored session. Your master password is needed next time."
        alert.addButton(withTitle: "Lock and Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.lockAndForget() }
    }

    @objc private func openSettings() {
        model.showSettings?(nil)
    }

    @objc private func openAbout() {
        showAbout()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

private struct MenuHeader: View {
    let title: String
    let detail: String?
    let warning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if warning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
