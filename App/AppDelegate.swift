import AppKit
import VaultLightCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.vaultlight.app", category: "app")

    private var panelController: PanelController?
    private var statusItem: StatusItemController?
    private var hotKey: HotKey?
    /// The one clipboard manager over the system pasteboard (spec 6).
    private let clipboard = ClipboardManager(pasteboard: NSPasteboard.general)

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
            if let directory = DemoScreens.requestedDirectory() {
                // Screenshot mode: no SessionManager, no bw, no status item, no hotkey.
                Task { @MainActor in
                    await DemoScreens.run(into: directory)
                    NSApplication.shared.terminate(nil)
                }
                return
            }
        #endif

        let controller = PanelController.makeProduction(clipboard: clipboard)
        let status = StatusItemController(clipboard: clipboard, onOpen: { [weak controller] in controller?.toggle() })
        let hotKey = HotKey { [weak controller] in controller?.toggle() }
        if !hotKey.register() {
            Self.logger.error("Registering the global shortcut failed")
            status.showShortcutUnavailable()
        }
        panelController = controller
        statusItem = status
        self.hotKey = hotKey
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A secret still on the clipboard is cleared on quit too (spec 6.2).
        clipboard.clearPendingSecret()
        hotKey?.stop()
    }
}
