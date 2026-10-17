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
                    let controller = PanelController(
                        vault: DemoVault(), system: DemoSystem(), session: nil, opaqueBackground: opaque)
                    controller.panel.appearance = appearance
                    await drive(controller, to: screen)
                    try? await Task.sleep(for: .milliseconds(500))
                    if let data = png(of: controller.panel) {
                        try? data.write(to: directory.appending(path: "\(screen.rawValue)-\(suffix).png"))
                    }
                    controller.close()
                }
            }
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
            case .noResults:
                await controller.open()
                controller.queryText = "kubernetes"
                await controller.submitQuery()
            }
        }

        private static func png(of panel: NSPanel) -> Data? {
            guard let view = panel.contentView else { return nil }
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

    /// Does nothing: the demo never touches the clipboard or opens a browser.
    @MainActor
    final class DemoSystem: PanelSystem {
        func copySecret(_ value: String) throws {}
        func copyUsername(_ value: String) throws {}
        func open(_ url: URL) {}
    }
#endif
