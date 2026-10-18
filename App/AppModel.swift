import AppKit
import Observation
import ServiceManagement
import VaultLightCore
import os

/// The app's one owner of `bw`, the session, the settings and the hotkey, and the commands the menu and Settings run
/// (spec 3.5, 4.1, 8). Views and menus call in here; nothing else changes the session.
@MainActor
@Observable
final class AppModel {
    private static let logger = Logger(subsystem: "com.vaultlight.app", category: "app")

    let settings: SettingsStore
    let client: BWClient
    let session: SessionManager
    let clipboard: ClipboardManager
    let onboarding: OnboardingModel
    let panel: PanelController

    /// The saved shortcut couldn't be registered (spec 4.1): menu badge and "Choose Another Shortcut…".
    private(set) var shortcutUnavailable = false
    /// The vault state the panel last showed, for the menu (design 13).
    private(set) var lastState: VaultState?
    private(set) var summary = VaultSummary()
    /// The `bw` in use and its version, for Settings and About (designs 14, 15).
    private(set) var bwInUse: (path: String, version: String)?
    /// Background sync and Sync Now (spec 7.3, design 08), as `SessionManager` publishes it. Kept on the panel
    /// controller, whose footer shows it.
    var syncStatus: SyncStatus { panel.syncStatus }

    /// Opens Settings at a tab; `nil` reopens the last one. Set by the app delegate.
    @ObservationIgnored var showSettings: ((SettingsTab?) -> Void)?
    @ObservationIgnored private let hotKey: HotKey
    /// What `apply()` last pushed to the session and clipboard, so only real changes restart anything.
    @ObservationIgnored private var applied: AppSettings?
    /// Off in screenshot mode: nothing may start `bw` or replace the invented state.
    @ObservationIgnored var isLive = true
    @ObservationIgnored private var syncListener: Task<Void, Never>?

    init(clipboard: ClipboardManager, settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        self.clipboard = clipboard
        let current = settings.settings
        client = BWClient(configuredPath: current.bwPath)
        session = SessionManager(
            client: client, store: KeychainSessionStore(), settings: current.session,
            backgroundSyncInterval: current.backgroundSync.interval)
        onboarding = OnboardingModel(backend: CLIOnboardingBackend(client: client, session: session))
        let panel = PanelController(
            vault: session, clipboard: clipboard, session: session, client: client, onboarding: onboarding)
        self.panel = panel
        hotKey = HotKey { [weak panel] in panel?.toggle() }

        panel.onStateChange = { [weak self] state in self?.stateChanged(state) }
        panel.onOpenSettings = { [weak self] tab in self?.showSettings?(tab) }
        panel.configuredBWPath = { [weak settings] in settings?.settings.bwPath }
        apply()
        syncListener = Task { [weak self, session] in
            for await status in session.syncStatusUpdates {
                guard let self, isLive else { continue }
                panel.syncStatus = status
            }
        }
    }

    /// Registers the saved shortcut. Called once at launch.
    func start() {
        shortcutUnavailable = !hotKey.register(settings.settings.hotKey)
        if shortcutUnavailable { Self.logger.error("Registering the global shortcut failed") }
    }

    func stop() {
        hotKey.stop()
        syncListener?.cancel()
    }

    // MARK: Settings (spec 8)

    /// Changes settings that apply at once: session lifetimes, clipboard timeout, sync interval.
    func update(_ change: (inout AppSettings) -> Void) {
        change(&settings.settings)
        apply()
    }

    private func apply() {
        let current = settings.settings
        defer { applied = current }
        clipboard.clearAfter = current.clipboardTimeout.duration
        panel.storedMaximumAge = current.session.storedMaximumAge
        if applied?.session != current.session {
            let sessionSettings = current.session
            Task { await session.updateSettings(sessionSettings) }
        }
        if let applied, applied.backgroundSync != current.backgroundSync {
            let interval = current.backgroundSync.interval
            Task { await session.setBackgroundSyncInterval(interval) }
        }
    }

    /// Tries `shortcut`; when the system refuses it, the previous one is registered again (design 14 state 4).
    /// Returns whether the new shortcut is in use.
    func setShortcut(_ shortcut: HotKeyShortcut) -> Bool {
        guard isLive else { return false }
        guard hotKey.register(shortcut) else {
            if !shortcutUnavailable { _ = hotKey.register(settings.settings.hotKey) }
            return false
        }
        settings.settings.hotKey = shortcut
        shortcutUnavailable = false
        return true
    }

    /// A custom `bw` path, checked against spec 7.1 before it is used; `nil` auto-detects. Returns the problem
    /// when the path is refused.
    func setBWPath(_ path: String?) async -> SetupProblem? {
        guard isLive else { return nil }
        if let path {
            do {
                _ = try BWLocator().locate(configuredPath: path)
            } catch {
                if case .setupProblem(let problem) = PanelScreen(error: error) { return problem }
                return .notInstalled
            }
        }
        // The unlocked session never goes to a binary the user didn't unlock with: lock first.
        if path != settings.settings.bwPath { await session.lockNow() }
        settings.settings.bwPath = path
        await client.setConfiguredPath(path)
        await refreshBWInUse()
        return nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard isLive else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.settings.launchAtLogin = enabled
        } catch {
            Self.logger.error("Launch at login failed: \(String(describing: type(of: error)), privacy: .public)")
            settings.settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: Commands (spec 3.5, 7.3, 8)

    func lockNow() {
        guard isLive else { return }
        Task {
            await session.lockNow()
            await refreshSummary()
        }
    }

    /// "Lock and forget": `bw lock` and the stored session deleted. The menu confirms first.
    func lockAndForget() async {
        guard isLive else { return }
        do {
            try await session.lockAndForget()
        } catch {
            Self.logger.error("Lock and forget failed: \(diagnosticKind(of: error), privacy: .public)")
        }
        lastState = nil
        await refreshSummary()
    }

    /// "Sign out" (spec 3.5). Throws when `bw logout` failed: the local session is gone, but `bw` is still signed in,
    /// so onboarding can't start yet.
    func signOut() async throws {
        guard isLive else { return }
        _ = try await session.signOut()
        onboarding.restart()
        panel.showOnboarding()
        await refreshSummary()
    }

    /// A new server (spec 8): sign out first, because `bw config server` only works while logged out, then resume
    /// onboarding at sign-in. The caller confirms first.
    func changeServer(to server: ServerChoice) async throws {
        guard isLive else { return }
        guard let url = server.url else { throw BWError.invalidArgument }
        do {
            _ = try await session.signOut()
        } catch {
            // The local session is gone, but `bw` is still signed in: no onboarding, server unchanged.
            throw ServerChangeError.signOutFailed
        }
        do {
            try await client.configServer(url)
        } catch {
            // Signed out, server unchanged: onboarding starts at the server step.
            onboarding.restart()
            panel.showOnboarding()
            throw error
        }
        settings.settings.server = server
        onboarding.resume(signInWith: server)
        panel.showOnboarding()
        await refreshSummary()
    }

    /// Joins a sync that is already running; the outcome reaches the footer, menu and Settings via `syncStatus`.
    func syncNow() async {
        guard isLive else { return }
        do {
            try await session.sync()
        } catch {
            Self.logger.error("Sync failed: \(diagnosticKind(of: error), privacy: .public)")
        }
    }

    // MARK: State for the menu, Settings and About

    func refreshSummary() async {
        guard isLive else { return }
        summary = await session.summary()
        if summary.isUnlocked { lastState = .unlocked } else if lastState == .unlocked { lastState = nil }
    }

    /// The located `bw` and its version (starts `bw --version` once per path).
    func refreshBWInUse() async {
        guard isLive else { return }
        do {
            let path = try await client.executable().url.path
            let version = try await client.checkVersion()
            bwInUse = (path, version.description)
        } catch {
            bwInUse = nil
        }
    }

    #if DEBUG
        /// Screenshot mode: invented state for the menu, Settings and About.
        func setDemoState(
            _ state: VaultState?, summary demoSummary: VaultSummary, shortcutUnavailable unavailable: Bool = false,
            lastSyncedAt synced: Date? = nil, bwInUse inUse: (path: String, version: String)? = nil
        ) {
            isLive = false
            lastState = state
            summary = demoSummary
            shortcutUnavailable = unavailable
            panel.syncStatus = SyncStatus(lastSyncedAt: synced)
            bwInUse = inUse
        }
    #endif

    private func stateChanged(_ state: VaultState?) {
        lastState = state
        Task {
            await refreshSummary()
            // Settings shows the server `bw` actually uses.
            if state != .needsOnboarding, let server = summary.serverURL {
                settings.settings.server = ServerChoice(serverURL: server)
            }
        }
    }
}

/// Why a server change stopped before `bw config server`.
enum ServerChangeError: Error {
    case signOutFailed
}

/// The Settings tabs (design 14).
enum SettingsTab: Int, CaseIterable {
    case general
    case security
    case vault
}
