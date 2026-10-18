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
    private var signalSources: [any DispatchSourceSignal] = []

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

        quitOnTerminationSignals()
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
        hotKey?.stop()
    }
}
