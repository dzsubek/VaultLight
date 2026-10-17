import SwiftUI
import VaultLightCore

/// Placeholder: a menu-bar item with Quit, until the panel, hotkey and status item exist.
@main
struct VaultLightApp: App {
    var body: some Scene {
        MenuBarExtra("VaultLight", systemImage: "magnifyingglass") {
            Text("VaultLight \(VaultLightCore.version)")
            Divider()
            Button("Quit VaultLight") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
