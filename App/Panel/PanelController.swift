import AppKit
import Observation
import SwiftUI
import VaultLightCore
import os

/// Owns the panel, its view model and the vault state it shows (spec 4). The panel is created once and reused:
/// closing calls `orderOut` and keeps the view hierarchy.
@MainActor
@Observable
final class PanelController {
    private static let logger = Logger(subsystem: "com.vaultlight.app", category: "panel")

    let viewModel: PanelViewModel
    private(set) var content: PanelContent
    /// The search field's text. The view sends changes to the view model through `submitQuery()`.
    var queryText = ""
    /// Bumped on every open so the view puts focus in the search field again.
    private(set) var openCount = 0

    @ObservationIgnored let panel: SearchPanel
    @ObservationIgnored private let session: SessionManager?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var anchor = CGPoint.zero
    @ObservationIgnored private var isOpening = false
    /// The Touch ID sheet is up: resigning key must not close the panel under it.
    @ObservationIgnored private var isAuthenticating = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(vault: any PanelVault, system: any PanelSystem, session: SessionManager?, opaqueBackground: Bool = false) {
        viewModel = PanelViewModel(vault: vault, system: system)
        self.session = session
        content = session == nil ? .unlocked : .checking
        panel = SearchPanel(contentSize: CGSize(width: PanelMetrics.width, height: PanelMetrics.lockedHeight))
        panel.install(SearchView(controller: self), opaqueBackground: opaqueBackground)
        panel.onResignKey = { [weak self] in self?.panelResignedKey() }
        panel.onCancel = { [weak self] in self?.close() }

        guard let session else { return }
        let events = SystemEvents.stream()
        tasks.append(Task { await session.observe(events) })
        tasks.append(
            Task { [weak self] in
                for await _ in session.sessionCleared {
                    self?.sessionWasCleared()
                }
            })
    }

    /// The production wiring: a `SessionManager` over the default `BWClient` and the Keychain store.
    static func makeProduction() -> PanelController {
        let session = SessionManager(client: BWClient(), store: KeychainSessionStore())
        return PanelController(vault: session, system: PasteboardWriter(), session: session)
    }

    // MARK: Open and close (spec 4.1–4.3)

    func toggle() {
        if panel.isVisible {
            close()
        } else {
            Task { await open() }
        }
    }

    func open() async {
        guard !panel.isVisible, !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        anchor = NSEvent.mouseLocation
        queryText = ""
        // A search is a few microseconds, so results are ready before the panel appears (no stale rows).
        if content == .unlocked { await viewModel.panelWillOpen() }
        applyFrame()
        openCount += 1
        panel.makeKeyAndOrderFront(nil)  // never NSApp.activate: the previous app stays frontmost
        installKeyMonitor()
        await refreshVaultState()
    }

    func close() {
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    private func panelResignedKey() {
        guard !isAuthenticating, panel.isVisible else { return }
        close()
    }

    /// The in-memory session was cleared (spec 3.5, 4.3).
    private func sessionWasCleared() {
        viewModel.reset()
        queryText = ""
        content = .checking
        close()
    }

    // MARK: Layout

    /// Resizes the panel for the current content. The top edge stays where `PanelPlacement` puts it, so the panel
    /// grows downward and the search field doesn't move.
    func applyFrame() {
        let height: CGFloat
        switch content {
        case .unlocked:
            height = PanelMetrics.height(
                unlockedRowCount: viewModel.results.count, hasSection: viewModel.section != nil)
        default:
            height = PanelMetrics.lockedHeight
        }
        let size = CGSize(width: PanelMetrics.width, height: height)
        let frame = PanelPlacement.frame(
            panelSize: size, screens: NSScreen.screens.map(\.visibleFrame), mouse: anchor)
        panel.setFrame(frame, display: true)
    }

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

    private func handle(_ outcome: PanelOutcome) {
        switch outcome {
        case .stayOpen:
            break
        case .close:
            close()
        case .closeAndOpenSettings:
            close()
            // Settings doesn't exist yet.
            Self.logger.debug("settings requested")
        }
    }

    // MARK: Vault state (interim)

    private func refreshVaultState() async {
        guard let session else { return }
        do {
            await apply(try await session.refreshState())
        } catch {
            content = .problem(PanelProblem(error))
            applyFrame()
        }
    }

    private func apply(_ state: VaultState) async {
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
        case .needsMasterPassword:
            content = .masterPassword(failed: false, busy: false)
            applyFrame()
        case .needsOnboarding:
            content = .needsOnboarding
            applyFrame()
        }
    }

    /// Reads the stored session behind Touch ID (spec 3.4). Return retries after a cancel.
    func unlockWithTouchID() async {
        guard let session, panel.isVisible, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            await apply(try await session.unlockWithStoredSession(reason: "unlock VaultLight"))
        } catch SessionStoreError.cancelled, SessionStoreError.authenticationFailed {
            content = .touchID(canceled: true)
        } catch {
            content = .problem(PanelProblem(error))
            applyFrame()
        }
    }

    /// `bw unlock` with the master password. The caller clears its field before calling; the password lives
    /// only in this call's parameter.
    func unlock(masterPassword: String) async {
        guard let session, case .masterPassword = content else { return }
        content = .masterPassword(failed: false, busy: true)
        do {
            await apply(try await session.unlock(masterPassword: masterPassword))
        } catch BWError.invalidPassword {
            content = .masterPassword(failed: true, busy: false)
        } catch {
            content = .problem(PanelProblem(error))
            applyFrame()
        }
    }

    // MARK: Keys (spec 5.4)

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns whether the event was consumed.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        // An input method composing text owns Return, arrows and Escape.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        guard let key = Self.key(for: event) else {
            return Self.isTab(event)  // Tab does nothing
        }
        switch content {
        case .unlocked:
            Task { await perform(key) }
            return true
        case .touchID:
            if key == .returnKey { Task { await unlockWithTouchID() } }
            if key == .escape { close() }
            return key == .returnKey || key == .escape
        default:
            // Interim locked views: Escape closes; Return belongs to the secure field.
            if key == .escape {
                close()
                return true
            }
            return false
        }
    }

    private static func isTab(_ event: NSEvent) -> Bool {
        event.keyCode == 48 && event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask)
    }

    /// Key codes: 126 up, 125 down, 36 Return, 76 keypad Enter, 53 Escape.
    static func key(for event: NSEvent) -> PanelKey? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        if modifiers.isEmpty { return plainKey(keyCode: event.keyCode) }
        guard modifiers == .command, let character = event.charactersIgnoringModifiers?.lowercased() else {
            return nil
        }
        return commandKey(character)
    }

    private static func plainKey(keyCode: UInt16) -> PanelKey? {
        switch keyCode {
        case 126: .up
        case 125: .down
        case 36, 76: .returnKey
        case 53: .escape
        default: nil
        }
    }

    private static func commandKey(_ character: String) -> PanelKey? {
        switch character {
        case "p": .copyPassword
        case "u": .copyUsername
        case "t": .copyTOTP
        case "o": .openURL
        case ",": .openSettings
        default: nil
        }
    }
}
