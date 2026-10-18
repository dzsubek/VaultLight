import AppKit
import Observation
import SwiftUI
import VaultLightCore
import os

/// Owns the panel, its view models and the vault state it shows (spec 3.1, 4). The panel is created once and reused:
/// closing calls `orderOut` and keeps the view hierarchy.
@MainActor
@Observable
final class PanelController {
    static let logger = Logger(subsystem: "com.vaultlight.app", category: "panel")

    let viewModel: PanelViewModel
    let onboarding: OnboardingModel
    /// Drives the footer's "Clears in" countdown (design 04).
    let clipboard: ClipboardManager
    private(set) var content: PanelContent
    /// Email, server and stored-session expiry for the locked screens (designs 06, 07).
    private(set) var summary = VaultSummary()
    /// The `bw` path a setup problem names (design 09 small print).
    private(set) var setupPath: String?
    /// For the onboarding unlock step's "Touch ID unlocks VaultLight for up to …" (design 12).
    var storedMaximumAge = SessionSettings.StoredMaximumAge.sevenDays
    /// The setup command was just copied: the button says "Copied" for 2 s (design 09).
    private(set) var commandCopied = false
    /// Background sync and Sync Now for the footer (spec 7.3, design 08); `AppModel` keeps it current.
    var syncStatus = SyncStatus()
    /// The search field's text. The view sends changes to the view model through `submitQuery()`.
    var queryText = ""
    /// Bumped on every open so the view puts focus in its first field again.
    private(set) var openCount = 0
    /// Bumped on every close so the locked and onboarding views drop half-typed secrets (no secret
    /// outlives the panel).
    private(set) var closeCount = 0
    /// The height a non-search screen reported; the panel is sized to it.
    var reportedHeight: CGFloat = 0 {
        didSet {
            if reportedHeight != oldValue { applyFrame() }
        }
    }

    /// The vault state the panel last learned, for the menu (design 13).
    @ObservationIgnored var onStateChange: ((VaultState?) -> Void)?
    /// ⌘, from the panel; the setup screens open the Vault tab at the `bw` path (design 09).
    @ObservationIgnored var onOpenSettings: ((SettingsTab?) -> Void)?
    /// The configured `bw` path, for the "not found" small print.
    @ObservationIgnored var configuredBWPath: () -> String? = { nil }

    @ObservationIgnored let panel: SearchPanel
    @ObservationIgnored let session: SessionManager?
    @ObservationIgnored private let client: BWClient?
    @ObservationIgnored var keyMonitor: Any?
    @ObservationIgnored private var anchor = CGPoint.zero
    @ObservationIgnored private var isOpening = false
    /// The Touch ID sheet is up: resigning key must not close the panel under it.
    @ObservationIgnored private var isAuthenticating = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var commandCopiedReset: Task<Void, Never>?

    init(
        vault: any PanelVault, clipboard: ClipboardManager, session: SessionManager?, client: BWClient? = nil,
        onboarding: OnboardingModel, openURL: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        opaqueBackground: Bool = false
    ) {
        viewModel = PanelViewModel(vault: vault, system: SystemActions(clipboard: clipboard, openURL: openURL))
        self.clipboard = clipboard
        self.session = session
        self.client = client
        self.onboarding = onboarding
        content = session == nil ? .unlocked : .checking
        panel = SearchPanel(contentSize: CGSize(width: PanelMetrics.width, height: PanelMetrics.lockedHeight))
        panel.install(SearchView(controller: self), opaqueBackground: opaqueBackground)
        panel.onResignKey = { [weak self] in self?.panelResignedKey() }
        panel.onCancel = { [weak self] in self?.close() }

        guard let session else { return }
        let events = SystemEvents.stream()
        tasks.append(Task { await session.observe(events) })
        // Sleep, screen lock and user switch also drop onboarding's held master password, whatever is on screen.
        let onboardingEvents = SystemEvents.stream()
        tasks.append(
            Task { [weak self] in
                for await _ in onboardingEvents {
                    self?.onboarding.dropHeldSecrets()
                    if self?.panel.isVisible == true { self?.close() }
                }
            })
        tasks.append(
            Task { [weak self] in
                for await _ in session.sessionCleared {
                    self?.sessionWasCleared()
                }
            })
    }

    // MARK: Open and close (spec 4.1–4.3)

    func toggle() {
        if panel.isVisible, !panel.isKeyWindow {
            // Left open while the user fetched a two-step code in another app: bring it back, don't close it.
            panel.makeKeyAndOrderFront(nil)
        } else if panel.isVisible {
            close()
        } else {
            Task { await open() }
        }
    }

    func open() async {
        guard !panel.isVisible, !isOpening else { return }
        isOpening = true
        anchor = NSEvent.mouseLocation
        queryText = ""
        // The panel opens at once in every state (spec 3.4 step 1): only the in-memory check runs first. It starts
        // no process, and it clears an expired session here, so results are loaded only for a valid one.
        if let session {
            content = await session.enforcePolicy() ? .unlocked : .checking
        }
        if content == .unlocked { await viewModel.panelWillOpen() }
        applyFrame()
        openCount += 1
        panel.makeKeyAndOrderFront(nil)  // never NSApp.activate: the previous app stays frontmost
        installKeyMonitor()
        isOpening = false
        // Locked: ask `bw` and the Keychain only now that the panel is on screen (Touch ID needs it there).
        if session != nil, content != .unlocked { await refreshLockedState() }
    }

    func close() {
        closeCount += 1
        onboarding.panelDidClose()
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    private func panelResignedKey() {
        guard !isAuthenticating, panel.isVisible, !isWaitingForTwoStepCode else { return }
        close()
    }

    /// On the two-step step the panel stays open when the user switches apps to fetch the code (spec 4.3 exception,
    /// decided by the human 2026-10-18). The held master password still ends with the panel, sleep, screen lock or
    /// `OnboardingModel.passwordHoldLimit`.
    private var isWaitingForTwoStepCode: Bool {
        content == .onboarding && onboarding.step == .twoFactor
    }

    /// The in-memory session was cleared (spec 3.5, 4.3). While the panel is opening, or while it shows a locked
    /// state, this is only a content change: `open()` found the expired session and shows the locked state. Cleared
    /// while search is on screen: reset and close.
    private func sessionWasCleared() {
        viewModel.reset()
        queryText = ""
        syncStatus = SyncStatus()
        let wasShowingSearch = content == .unlocked
        if wasShowingSearch { content = .checking }
        if wasShowingSearch, !isOpening { close() }
        Task { await refreshSummary() }
    }

    /// Shows onboarding at once (after Sign Out or a server change, spec 3.5, 8), without asking `bw`.
    func showOnboarding() {
        viewModel.reset()
        content = .onboarding
        onStateChange?(.needsOnboarding)
        applyFrame()
        Task { await refreshSummary() }
    }

    func markCommandCopied() {
        commandCopied = true
        commandCopiedReset?.cancel()
        commandCopiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.commandCopied = false
        }
    }

    // MARK: Layout

    /// Resizes the panel for the current content. The top edge stays where `PanelPlacement` puts it, so the panel
    /// grows downward and the search field doesn't move.
    func applyFrame() {
        let height: CGFloat
        if content == .unlocked {
            height = PanelMetrics.height(
                unlockedRowCount: viewModel.results.count, hasSection: viewModel.section != nil)
        } else {
            height = reportedHeight > 0 ? reportedHeight : PanelMetrics.lockedHeight
        }
        let size = CGSize(width: PanelMetrics.width, height: height)
        let frame = PanelPlacement.frame(panelSize: size, screens: NSScreen.screens.map(\.visibleFrame), mouse: anchor)
        panel.setFrame(frame, display: true)
    }

    // MARK: Vault state (spec 3.1)

    func refreshLockedState() async {
        guard let session else { return }
        do {
            await apply(try await session.refreshState())
        } catch {
            await show(error)
        }
    }

    private func show(_ error: any Error) async {
        Self.logger.error("Vault state failed: \(diagnosticKind(of: error), privacy: .public)")
        let screen = PanelScreen(error: error)
        if case .setupProblem(let problem) = screen {
            setupPath = problem == .notInstalled ? configuredBWPath() : (try? await client?.executable())?.url.path
        }
        if screen == .onboarding { onStateChange?(.needsOnboarding) }
        content = PanelContent(screen)
        applyFrame()
    }

    func apply(_ state: VaultState) async {
        onStateChange?(state)
        await refreshSummary()
        switch state {
        case .unlocked:
            let wasUnlocked = content == .unlocked
            content = .unlocked
            if !wasUnlocked { await viewModel.panelWillOpen() }
            applyFrame()
        case .storedSessionAvailable:
            content = .touchID(canceled: false)
            applyFrame()
            await unlockWithTouchID()
        case .needsMasterPassword(let reason):
            // Signed in during onboarding but not unlocked yet: stay on onboarding's unlock step (design 12).
            content = onboarding.step == .unlock ? .onboarding : .masterPassword(reason, attempts: 0, busy: false)
            applyFrame()
        case .needsOnboarding:
            // `bw` was logged out meanwhile: the unlock step can't work any more.
            if onboarding.step == .unlock || onboarding.step == .finishing { onboarding.restart() }
            content = .onboarding
            applyFrame()
        }
    }

    func refreshSummary() async {
        guard let session else { return }
        summary = await session.summary()
    }

    /// Reads the stored session behind Touch ID (spec 3.4). Return retries after a cancel.
    func unlockWithTouchID() async {
        guard let session, panel.isVisible, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            await apply(try await session.unlockWithStoredSession(reason: String(localized: "unlock your vault")))
        } catch SessionStoreError.cancelled, SessionStoreError.authenticationFailed {
            content = .touchID(canceled: true)
        } catch {
            await show(error)
        }
    }

    /// `bw unlock` with the master password (design 07). The caller clears its field before calling; the password
    /// lives only in this call's parameter.
    func unlock(masterPassword: String) async {
        guard let session, case .masterPassword(let reason, let attempts, false) = content else { return }
        content = .masterPassword(reason, attempts: attempts, busy: true)
        do {
            await apply(try await session.unlock(masterPassword: masterPassword))
        } catch BWError.invalidPassword {
            content = .masterPassword(reason, attempts: attempts + 1, busy: false)
        } catch {
            await show(error)
        }
    }

    /// Onboarding's last step (design 12): the checklist, then search in place.
    func finishOnboarding(masterPassword: String) async {
        guard content == .onboarding else { return }
        guard await onboarding.unlock(masterPassword: masterPassword) else { return }
        // Long enough to see the ticked checklist.
        try? await Task.sleep(for: .milliseconds(600))
        guard content == .onboarding, panel.isVisible else {
            onStateChange?(.unlocked)
            await refreshSummary()
            return
        }
        await apply(.unlocked)
    }
}

/// Search and its keys (spec 5.4).
extension PanelController {
    // MARK: Search

    /// Sends `queryText` to the view model, then resizes for the new result count.
    func submitQuery() async {
        // The field's change handler calls this too; a search for the text the view model already has is skipped.
        guard content == .unlocked, queryText != viewModel.query else { return }
        await viewModel.setQuery(queryText)
        applyFrame()
    }

    /// Runs a key through the view model and acts on its outcome (spec 5.4).
    func perform(_ key: PanelKey) async {
        guard content == .unlocked else { return }
        handle(await viewModel.handle(key))
    }

    func select(index: Int) {
        viewModel.select(index: index)
    }

    func activate(index: Int) async {
        guard content == .unlocked else { return }
        handle(await viewModel.activate(index: index))
    }

    /// "Try again" in the footer (design 16).
    func retry() async {
        guard content == .unlocked else { return }
        handle(await viewModel.retry())
    }

    func handle(_ outcome: PanelOutcome) {
        switch outcome {
        case .stayOpen:
            break
        case .close:
            close()
        case .closeAndOpenSettings:
            openSettings()
        }
    }

    /// ⌘,: closes the panel and opens Settings, at the `bw` path when `bw` is the problem (design 09).
    func openSettings() {
        close()
        if case .setupProblem = content {
            onOpenSettings?(.vault)
        } else {
            onOpenSettings?(nil)
        }
    }

    #if DEBUG
        /// Screenshot mode: shows a screen with invented data, without a session.
        func showDemo(
            _ demoContent: PanelContent, summary demoSummary: VaultSummary = VaultSummary(),
            setupPath path: String? = nil
        ) {
            content = demoContent
            summary = demoSummary
            setupPath = path
            applyFrame()
        }
    #endif
}
