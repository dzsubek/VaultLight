import AppKit
import SwiftUI
import VaultLightCore

/// Settings → Vault (spec 3.5, 7.1, 8, design 14 state 3): the account with Sign Out…, the server, sync and the
/// `bw` location. Signing out and changing the server ask first.
struct VaultSettingsView: View {
    let model: AppModel

    private enum ServerOption: Hashable {
        case bitwardenUS, bitwardenEU, selfHosted
    }

    private enum Location: Hashable {
        case automatic, custom
    }

    @State private var confirmingSignOut = false
    @State private var signOutFailed = false
    @State private var pendingServer: ServerChoice?
    @State private var serverChangeFailed = false
    @State private var editingSelfHosted = false
    @State private var selfHostedAddress = ""
    @State private var refusedPath: SetupProblem?

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Account", footer: "Changing the server signs you out.") {
                SettingsRow(title: accountTitle, subtitle: accountSubtitle) {
                    Button("Sign Out…") { confirmingSignOut = true }
                        .disabled(!isSignedIn)
                }
                SettingsRow(title: "Server", divider: true) {
                    Picker("", selection: serverSelection) {
                        Text("Bitwarden US").tag(ServerOption.bitwardenUS)
                        Text("Bitwarden EU").tag(ServerOption.bitwardenEU)
                        Text(selfHostedLabel).tag(ServerOption.selfHosted)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if editingSelfHosted {
                    SettingsRow(title: "Server address", divider: true) {
                        HStack(spacing: 8) {
                            TextField("https://vault.example.com", text: $selfHostedAddress)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, design: .monospaced))
                                .frame(width: 240)
                                .onSubmit(useSelfHosted)
                            Button("Use Server", action: useSelfHosted)
                                .disabled(ServerChoice.selfHosted(selfHostedAddress).url == nil)
                        }
                    }
                }
            }
            SettingsSection(title: "Sync") {
                SettingsRow(title: "Background sync") {
                    OptionPicker(
                        selection: Binding(
                            get: { model.settings.settings.backgroundSync },
                            set: { value in model.update { $0.backgroundSync = value } }),
                        options: AppSettings.SyncInterval.allCases,
                        label: {
                            switch $0 {
                            case .off: "Off"
                            case .fiveMinutes: "Every 5 minutes"
                            case .fifteenMinutes: "Every 15 minutes"
                            case .sixtyMinutes: "Every hour"
                            }
                        })
                }
                SettingsRow(title: "Last synced", divider: true) {
                    HStack(spacing: 10) {
                        Text(lastSynced).font(.system(size: 13)).foregroundStyle(.secondary)
                        Button("Sync Now") { Task { await model.syncNow() } }
                            .disabled(!model.summary.isUnlocked || model.isSyncing)
                    }
                }
            }
            SettingsSection(
                title: "Bitwarden CLI",
                footer: refusedPath.map { "\($0.title). \($0.detail(path: nil))" }
                    ?? "VaultLight never looks up bw through PATH, and refuses a binary that other users can modify."
            ) {
                SettingsRow(title: "Location", subtitle: model.settings.settings.bwPath) {
                    Picker("", selection: locationSelection) {
                        Text("Auto-detect").tag(Location.automatic)
                        Text("Custom…").tag(Location.custom)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(title: "In use", divider: true) {
                    Text(model.bwInUse.map { "\($0.path) · \($0.version)" } ?? "Not found")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .task { await model.refreshBWInUse() }
        .alert("Sign out of Bitwarden?", isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive, action: signOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "VaultLight deletes the stored session, clears the unlocked vault and signs out of the Bitwarden CLI. "
                    + "Your settings are kept.")
        }
        .alert("Sign out didn’t finish", isPresented: $signOutFailed) {
            Button("Retry Sign Out", action: signOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The vault is locked and the stored session is gone, but the Bitwarden CLI is still signed in.")
        }
        .alert(
            "Change the server?",
            isPresented: Binding(get: { pendingServer != nil }, set: { if !$0 { pendingServer = nil } })
        ) {
            Button("Sign Out and Change", role: .destructive, action: changeServer)
            Button("Cancel", role: .cancel) { pendingServer = nil }
        } message: {
            Text(
                "VaultLight signs you out first, because the Bitwarden CLI can only change servers while signed out. "
                    + "Then sign in on \(pendingServer?.displayName ?? "the new server").")
        }
        .alert("The server wasn’t changed", isPresented: $serverChangeFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You are signed out. Open VaultLight to choose the server and sign in.")
        }
    }

    // MARK: Account

    private var isSignedIn: Bool {
        model.summary.email != nil || model.summary.isUnlocked
            || (model.lastState != nil && model.lastState != .needsOnboarding)
    }

    private var accountTitle: String {
        model.summary.email ?? (isSignedIn ? "Signed in" : "Not signed in")
    }

    private var accountSubtitle: String {
        if model.summary.isUnlocked {
            return model.summary.loginCount.map { "Signed in · \($0) logins" } ?? "Signed in"
        }
        return isSignedIn ? "Signed in · locked" : "Open VaultLight to sign in"
    }

    private func signOut() {
        Task {
            do {
                try await model.signOut()
            } catch {
                signOutFailed = true
            }
        }
    }

    // MARK: Server

    private var selfHostedLabel: String {
        if case .selfHosted = model.settings.settings.server { return model.settings.settings.server.displayName }
        return "Self-hosted…"
    }

    private var serverSelection: Binding<ServerOption> {
        Binding(
            get: {
                if editingSelfHosted { return .selfHosted }
                switch model.settings.settings.server {
                case .bitwardenUS: return .bitwardenUS
                case .bitwardenEU: return .bitwardenEU
                case .selfHosted: return .selfHosted
                }
            },
            set: { option in
                switch option {
                case .bitwardenUS: request(.bitwardenUS)
                case .bitwardenEU: request(.bitwardenEU)
                case .selfHosted:
                    if case .selfHosted(let address) = model.settings.settings.server { selfHostedAddress = address }
                    editingSelfHosted = true
                }
            })
    }

    private func request(_ server: ServerChoice) {
        editingSelfHosted = false
        guard server != model.settings.settings.server else { return }
        pendingServer = server
    }

    private func useSelfHosted() {
        let server = ServerChoice.selfHosted(selfHostedAddress.trimmingCharacters(in: .whitespacesAndNewlines))
        guard server.url != nil else { return }
        editingSelfHosted = false
        if server != model.settings.settings.server { pendingServer = server }
    }

    private func changeServer() {
        guard let server = pendingServer else { return }
        pendingServer = nil
        Task {
            do {
                try await model.changeServer(to: server)
            } catch {
                serverChangeFailed = true
            }
        }
    }

    // MARK: Sync and bw

    private var lastSynced: String {
        guard let date = model.lastSyncedAt else { return "Not this session" }
        return RelativeTime.ago(Date().timeIntervalSince(date))
    }

    private var locationSelection: Binding<Location> {
        Binding(
            get: { model.settings.settings.bwPath == nil ? .automatic : .custom },
            set: { location in
                switch location {
                case .automatic:
                    refusedPath = nil
                    Task { _ = await model.setBWPath(nil) }
                case .custom:
                    chooseCustomPath()
                }
            })
    }

    /// A file picker for a custom `bw`; the path is checked against spec 7.1 before it is used.
    private func chooseCustomPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the Bitwarden CLI (bw)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { refusedPath = await model.setBWPath(url.path) }
    }
}
