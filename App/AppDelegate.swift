import AppKit
import VaultLightCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The one clipboard manager over the system pasteboard (spec 6).
    private let clipboard = ClipboardManager(pasteboard: NSPasteboard.general)
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var aboutWindow: AboutWindowController?
    private var signalSources: [any DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        #if DEBUG
            if let directory = DemoScreens.requestedDirectory() {
                // Screenshot mode: no bw, no Keychain, no status item, no hotkey.
                Task { @MainActor in
                    await DemoScreens.run(into: directory)
                    NSApplication.shared.terminate(nil)
                }
                return
            }
        #endif

        quitOnTerminationSignals()
        let model = AppModel(clipboard: clipboard)
        let settingsWindow = SettingsWindowController(model: model)
        let aboutWindow = AboutWindowController(model: model)
        model.showSettings = { [weak settingsWindow] tab in settingsWindow?.show(tab: tab) }
        statusItem = StatusItemController(model: model, showAbout: { [weak aboutWindow] in aboutWindow?.show() })
        model.start()
        self.model = model
        self.settingsWindow = settingsWindow
        self.aboutWindow = aboutWindow
    }

    /// `kill`, `killall` or `launchctl stop` end a process without `applicationWillTerminate`, which would leave a
    /// pending secret on the clipboard (spec 6.2). Turn those signals into a normal quit.
    private func quitOnTerminationSignals() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A secret still on the clipboard is cleared on quit too (spec 6.2).
        clipboard.clearPendingSecret()
        model?.stop()
    }
}

/// The menu bar shown while Settings or About is in front (design 14): VaultLight, Edit and Window, so the standard
/// editing and window shortcuts work in their fields.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(
            submenu(
                "VaultLight",
                items: [
                    NSMenuItem(title: "Hide VaultLight", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
                    .separator(),
                    NSMenuItem(
                        title: "Quit VaultLight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
                ]))
        main.addItem(
            submenu(
                "Edit",
                items: [
                    NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
                    NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"),
                    .separator(),
                    NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
                    NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
                    NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
                    NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
                ]))
        let window = submenu(
            "Window",
            items: [
                NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
                NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
            ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
    }

    private static func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }
}
