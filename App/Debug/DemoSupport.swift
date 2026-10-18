#if DEBUG
    import AppKit
    import SwiftUI
    import VaultLightCore

    /// The panel's opaque backdrop as a SwiftUI view, for the composite images.
    struct SheetBackground: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { SolidBackdropView() }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    /// A drawn copy of the menu: the header item's own view, then each item's title, shortcut and enabled state.
    struct MenuSnapshot: View {
        let items: [NSMenuItem]

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    if item.isSeparatorItem {
                        Divider().padding(.horizontal, 10).padding(.vertical, 5)
                    } else if let view = item.view {
                        HostedItem(view: view).frame(width: view.frame.width, height: view.frame.height)
                    } else {
                        HStack {
                            Text(item.title)
                            Spacer()
                            Text(shortcut(item)).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(item.isEnabled ? .primary : .tertiary)
                        .padding(.horizontal, 14)
                        .frame(height: 22)
                    }
                }
            }
            .padding(.vertical, 5)
            .frame(width: 300)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        }

        private func shortcut(_ item: NSMenuItem) -> String {
            guard !item.keyEquivalent.isEmpty else { return "" }
            let flags = item.keyEquivalentModifierMask
            var text = ""
            if flags.contains(.command) { text += "⌘" }
            if flags.contains(.shift) { text += "⇧" }
            if flags.contains(.option) { text += "⌥" }
            if flags.contains(.control) { text += "⌃" }
            return text + (item.keyEquivalent == " " ? "Space" : item.keyEquivalent.uppercased())
        }
    }

    struct HostedItem: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    /// Onboarding with canned answers: no `bw`, no network. The behaviors pick the design's state.
    struct DemoOnboardingBackend: OnboardingBackend {
        enum Login: Sendable {
            case success, wrongPassword, twoFactor, offline
        }

        var login = Login.success
        var unlockHangs = false

        func configServer(_ url: URL) async throws {}

        func loginPassword(email: String, password: String, twoFactor: BWTwoFactor?) async throws {
            if let twoFactor {
                if twoFactor.code == "000000" { throw BWError.invalidTwoFactorCode }
                return
            }
            switch login {
            case .success: return
            case .wrongPassword: throw BWError.invalidPassword
            case .twoFactor: throw BWError.twoFactorRequired
            case .offline: throw BWError.network
            }
        }

        func loginAPIKey(clientID: String, clientSecret: String) async throws {}

        func status() async throws -> BWStatus {
            try JSONDecoder().decode(
                BWStatus.self,
                from: Data(#"{"status":"locked","userEmail":"\#(DemoScreens.demoEmail)"}"#.utf8))
        }

        func unlock(masterPassword: String, progress: @escaping @Sendable (UnlockProgress) -> Void) async throws
            -> VaultState
        {
            progress(.vaultUnlocked)
            progress(.sessionSaved(true))
            if unlockHangs { try await Task.sleep(for: .seconds(3_600)) }
            progress(.indexBuilt(logins: 214))
            return .unlocked
        }

        func logout() async throws {}
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
        func sync() async throws {}
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
