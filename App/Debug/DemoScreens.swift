#if DEBUG
    import AppKit
    import VaultLightCore

    /// DEBUG-only screenshot mode: `-VLScreenshotDir <absolute dir>`. Drives the real panel controller, panel and
    /// view model against an in-memory demo vault of invented entries and writes PNGs. No `SessionManager`, no `bw`,
    /// no Keychain, no real vault content.
    @MainActor
    enum DemoScreens {
        static func requestedDirectory() -> URL? {
            let arguments = CommandLine.arguments
            guard let flag = arguments.firstIndex(of: "-VLScreenshotDir"), flag + 1 < arguments.count,
                arguments[flag + 1].hasPrefix("/")
            else { return nil }
            return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        }

        private enum Screen: String, CaseIterable {
            case empty = "01-search-empty"
            case results = "02-search-results"
            case usernameCopied = "03-username-copied"
            case passwordCopied = "04-password-copied"
            case noResults = "05-no-results"
        }

        static func run(into directory: URL) async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let appearances: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
            for (name, suffix) in appearances {
                let appearance = NSAppearance(named: name)
                NSApp.appearance = appearance
                for screen in Screen.allCases {
                    // A fresh vault and controller per image, so one screen's copies never change another's ranking.
                    // The real clipboard manager over an in-memory pasteboard: the countdown is real, `.general` untouched.
                    let controller = PanelController(
                        vault: DemoVault(), clipboard: ClipboardManager(pasteboard: DemoPasteboard()), session: nil,
                        openURL: { _ in }, opaqueBackground: opaque)
                    controller.panel.appearance = appearance
                    await drive(controller, to: screen)
                    try? await Task.sleep(for: .milliseconds(500))
                    if let data = png(of: controller.panel) {
                        try? data.write(to: directory.appending(path: "\(screen.rawValue)-\(suffix).png"))
                    }
                    controller.close()
                }
                if let data = png(of: menuBarStrip(appearance: appearance)) {
                    try? data.write(to: directory.appending(path: "04-password-copied-menubar-\(suffix).png"))
                }
            }
        }

        /// The real menu-bar countdown image (`MenuBarIcon`) on a plain strip the size of the design's
        /// (1040×52 pt). The system menu bar itself can't be captured without screen-recording permission, so the
        /// clock and other system items are not drawn.
        private static func menuBarStrip(appearance: NSAppearance?) -> NSView {
            let strip = NSView(frame: NSRect(x: 0, y: 0, width: 1040, height: 52))
            strip.appearance = appearance
            strip.wantsLayer = true
            let isDark = appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            strip.layer?.backgroundColor =
                isDark
                ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1).cgColor
                : NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1).cgColor
            let image = MenuBarIcon.countdown(symbolName: "key.horizontal", seconds: 45)
            let icon = NSImageView(image: image)
            icon.contentTintColor = .labelColor
            icon.frame = NSRect(
                x: 1040 - 260 - image.size.width, y: (52 - image.size.height) / 2, width: image.size.width,
                height: image.size.height)
            strip.addSubview(icon)
            // A window gives the views an effective appearance; it is never shown.
            let window = NSWindow(
                contentRect: strip.frame, styleMask: .borderless, backing: .buffered, defer: true)
            window.contentView = strip
            return strip
        }

        /// Set to `true` when the translucent material doesn't survive `cacheDisplay`.
        private static let opaque = true

        private static func drive(_ controller: PanelController, to screen: Screen) async {
            switch screen {
            case .empty:
                // Real copies through the view model, oldest first, so the list shows "Recent", newest first.
                for name in ["Figma", "Hetzner Cloud", "Linear", "AWS Console", "Fastmail", "GitHub"] {
                    await controller.viewModel.setQuery(name)
                    await controller.perform(.copyUsername)
                }
                await controller.open()
            case .results:
                await controller.open()
                controller.queryText = "git"
                await controller.submitQuery()
                await controller.perform(.down)
            case .usernameCopied:
                await controller.open()
                controller.queryText = "git"
                await controller.submitQuery()
                await controller.perform(.down)
                await controller.perform(.copyUsername)
            case .passwordCopied:
                // Through the view model, not `perform`, so the panel stays on screen for the capture.
                await controller.open()
                controller.queryText = "git"
                await controller.submitQuery()
                await controller.perform(.down)
                _ = await controller.viewModel.handle(.returnKey)
            case .noResults:
                await controller.open()
                controller.queryText = "kubernetes"
                await controller.submitQuery()
            }
        }

        private static func png(of panel: NSPanel) -> Data? {
            panel.contentView.flatMap(png(of:))
        }

        private static func png(of view: NSView) -> Data? {
            let size = view.bounds.size
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return nil }
            rep.size = size
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])
        }
    }

    /// Invented entries copied from the designs. Search only, no `bw`.
    actor DemoVault: PanelVault {
        private var index: SearchIndex

        init() {
            let entries = [
                VaultEntry(
                    id: "github", name: "GitHub", username: "marta.keller@fastmail.com", uris: ["https://github.com"],
                    folderId: "work", favorite: true),
                VaultEntry(
                    id: "github-personal", name: "GitHub — personal", username: "mkeller-dev",
                    uris: ["https://github.com"], folderId: "personal", hasTOTP: true),
                VaultEntry(
                    id: "gitlab", name: "GitLab", username: "marta.keller", uris: ["https://gitlab.northwind.io"],
                    organizationId: "northwind", hasTOTP: true),
                VaultEntry(
                    id: "gitpod", name: "Gitpod", username: "marta.keller@fastmail.com", uris: ["https://gitpod.io"],
                    folderId: "work"),
                VaultEntry(
                    id: "forgejo", name: "Forgejo", username: "admin", uris: ["https://git.home.arpa"],
                    folderId: "homelab"),
                VaultEntry(
                    id: "digitec", name: "Digitec", username: "marta.keller@gmx.ch", uris: ["https://digitec.ch"],
                    folderId: "shopping"),
                VaultEntry(
                    id: "fastmail", name: "Fastmail", username: "marta.keller@fastmail.com",
                    uris: ["https://app.fastmail.com"], folderId: "personal", hasTOTP: true),
                VaultEntry(
                    id: "aws", name: "AWS Console", username: "marta.keller", uris: ["https://signin.aws.amazon.com"],
                    folderId: "work", hasTOTP: true),
                VaultEntry(
                    id: "linear", name: "Linear", username: "marta.keller@fastmail.com", uris: ["https://linear.app"],
                    folderId: "work"),
                VaultEntry(
                    id: "hetzner", name: "Hetzner Cloud", username: "mk-infra", uris: ["https://console.hetzner.cloud"],
                    folderId: "homelab"),
                VaultEntry(
                    id: "figma", name: "Figma", username: "marta.keller@fastmail.com", uris: ["https://figma.com"],
                    folderId: "work"),
            ]
            let folders = [
                VaultFolder(id: "work", name: "Work"), VaultFolder(id: "personal", name: "Personal"),
                VaultFolder(id: "homelab", name: "Homelab"), VaultFolder(id: "shopping", name: "Shopping"),
            ]
            index = SearchIndex(
                entries: entries, folders: folders,
                organizations: [VaultOrganization(id: "northwind", name: "Northwind Labs")])
        }

        func search(_ query: String) -> [SearchResult] { index.search(query) }
        func recordCopy(id: String) { index.recordCopy(id: id) }
        func password(for id: String) async throws -> String { "demo" }
        func totp(for id: String) async throws -> String { "000000" }
    }

    /// An in-memory pasteboard: the demo never touches the system clipboard.
    @MainActor
    final class DemoPasteboard: Clipboard {
        private(set) var changeCount = 0

        func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
            changeCount += 1
            return changeCount
        }

        func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool { true }

        func clearContents() -> Int {
            changeCount += 1
            return changeCount
        }
    }
#endif
