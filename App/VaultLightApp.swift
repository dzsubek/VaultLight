import AppKit

/// Entry point: an accessory (menu-bar) app with no Dock icon (spec 4). AppKit owns the life cycle, because the
/// panel, hotkey and status item are all AppKit objects.
@main
enum VaultLightMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
