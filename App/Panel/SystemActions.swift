import Foundation
import VaultLightCore

/// The panel's side effects (spec 5.4): copies go through the clipboard manager (spec 6), ⌘O opens the default
/// browser.
@MainActor
final class SystemActions: PanelSystem {
    private let clipboard: ClipboardManager
    private let openURL: @MainActor (URL) -> Void

    init(clipboard: ClipboardManager, openURL: @escaping @MainActor (URL) -> Void) {
        self.clipboard = clipboard
        self.openURL = openURL
    }

    func copySecret(_ value: String) throws {
        try clipboard.copySecret(value)
    }

    func copyUsername(_ value: String) throws {
        try clipboard.copyUsername(value)
    }

    func open(_ url: URL) {
        openURL(url)
    }
}
