import AppKit
import SwiftUI
import VaultLightCore

/// The About window (spec 11.5, design 15): the "not affiliated" disclaimer, the app version, and the `bw` version
/// and server in use, which help with bug reports.
@MainActor
final class AboutWindowController: NSWindowController {
    static let sourceURL = URL(string: "https://github.com/dzsubek/VaultLight")

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let hosting = NSHostingController(rootView: AboutView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.title = "About VaultLight"
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show() {
        Task { await model.refreshBWInUse() }
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    let model: AppModel
    @State private var showingLicenses = false

    var body: some View {
        VStack(spacing: 0) {
            AppMark(size: 80)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                .padding(.top, 38)
            Text("VaultLight")
                .font(.system(size: 17, weight: .bold))
                .padding(.top, 14)
            Text("Version \(Self.version)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text("An unofficial client for Bitwarden. VaultLight is not affiliated with or endorsed by Bitwarden, Inc.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .padding(.horizontal, 30)
            Text(cliLine)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            HStack(spacing: 16) {
                if let url = AboutWindowController.sourceURL {
                    Link("Source code", destination: url)
                }
                Button("Licenses") { showingLicenses = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $showingLicenses) {
                        Text("VaultLight includes no third-party code.")
                            .font(.system(size: 12))
                            .padding(12)
                    }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.teal)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .frame(width: 280)
        .background(Theme.groupedBackground)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var cliLine: String {
        let server = ServerChoice(serverURL: model.summary.serverURL).displayName
        guard let version = model.bwInUse?.version else { return "bw not found" }
        return "bw \(version) · \(model.summary.serverURL == nil ? model.settings.settings.server.displayName : server)"
    }
}
