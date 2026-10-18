import Foundation
import Observation

/// A key the panel handles (spec 5.4).
public enum PanelKey: Sendable, Equatable {
    // swiftlint:disable:next identifier_name
    case up
    case down
    /// Return: copy the password.
    case returnKey
    /// ⌘P
    case copyPassword
    /// ⌘U
    case copyUsername
    /// ⌘T
    case copyTOTP
    /// ⌘O
    case openURL
    case escape
    /// ⌘,
    case openSettings
}

/// What the panel does after a key (spec 5.4 "Panel after").
public enum PanelOutcome: Sendable, Equatable {
    case stayOpen
    case close
    case closeAndOpenSettings
}

/// The list heading for an empty query (spec 5.1).
public enum PanelSection: Sendable, Equatable {
    case recent
    case favorites
}

/// The footer line (spec 5.4). Fixed states with fixed copy: no vault content, no raw `bw` output.
public enum PanelFooter: Sendable, Equatable {
    case idle
    case usernameCopied
    case passwordCopied
    case codeCopied
    case noPassword
    case noTOTP
    case noUsername
    case noURL
    case copyFailed
    /// The clipboard write itself failed, so the clipboard was already wiped.
    case clipboardWriteFailed
    case timedOut
    case locked

    /// The text to show; `nil` when the footer shows its usual content.
    public var message: String? {
        switch self {
        case .idle: nil
        case .usernameCopied: "Username copied"
        case .passwordCopied: "Password copied"
        case .codeCopied: "One-time code copied"
        case .noPassword: "No password for this item"
        case .noTOTP: "No one-time code for this item"
        case .noUsername: "No username for this item"
        case .noURL: "No website for this item"
        case .copyFailed: "Copy failed · clipboard unchanged"
        case .clipboardWriteFailed: "Copy failed"
        case .timedOut: "bw didn't respond within 15 s"
        case .locked: "Vault is locked"
        }
    }
}

/// The panel's state and key handling (spec 4.2–5.4), with no UI. It never stores a secret: a fetched value
/// lives in a local until the clipboard write returns.
@MainActor
@Observable
public final class PanelViewModel {
    public private(set) var query = ""
    public private(set) var results: [SearchResult] = []
    public private(set) var selectedIndex: Int?
    public private(set) var section: PanelSection?
    public private(set) var footer: PanelFooter = .idle

    public var selected: SearchResult? { selectedIndex.map { results[$0] } }
    public var hasSelection: Bool { selectedIndex != nil }
    public var isTOTPAvailable: Bool { selected?.entry.hasTOTP ?? false }
    /// A copy failed or timed out, and "Try again" (or Return) repeats it (design 16 footer).
    public var canRetry: Bool { retryKey != nil }

    /// How long "Username copied" stays in the footer.
    static let usernameFooterDuration = Duration.seconds(2)

    @ObservationIgnored private let vault: any PanelVault
    @ObservationIgnored private let system: any PanelSystem
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// Set once a copy was recorded this session, so an empty query lists recents rather than favorites.
    @ObservationIgnored private var hasCopied = false
    /// Newest search wins: a slower, older search must not overwrite its results.
    @ObservationIgnored private var searchGeneration = 0
    /// Bumped by `reset()`; an action that started before it must not touch the clipboard afterwards.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var isBusy = false
    @ObservationIgnored private var footerRevert: Task<Void, Never>?
    /// The copy to repeat on "Try again". Observed, so the footer's button follows it.
    private var retryKey: PanelKey?

    public init(
        vault: any PanelVault, system: any PanelSystem,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.vault = vault
        self.system = system
        self.sleep = sleep
    }

    // MARK: Lifecycle

    /// The panel is about to be shown: empty query, idle footer, recents or favorites, row 0 selected (spec 4.2).
    public func panelWillOpen() async {
        show(.idle)
        await load(query: "")
    }

    /// The session was cleared (spec 3.5): drop everything the panel holds.
    public func reset() {
        epoch += 1
        searchGeneration += 1
        hasCopied = false
        isBusy = false
        query = ""
        results = []
        selectedIndex = nil
        section = nil
        show(.idle)
    }

    // MARK: Search and selection

    public func setQuery(_ newQuery: String) async {
        await load(query: newQuery)
    }

    /// A click on a row (spec 5.3).
    public func select(index: Int) {
        guard results.indices.contains(index) else { return }
        if index != selectedIndex { dropRetry() }
        selectedIndex = index
    }

    /// A double-click on a row: select it and run the Return action (spec 5.3).
    public func activate(index: Int) async -> PanelOutcome {
        select(index: index)
        return await handle(.returnKey)
    }

    /// "Try again": repeats the failed copy on the selected row (spec 7.4).
    public func retry() async -> PanelOutcome {
        guard let retryKey else { return .stayOpen }
        return await handle(retryKey)
    }

    private func load(query newQuery: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        query = newQuery
        let found = await vault.search(newQuery)
        guard generation == searchGeneration else { return }
        // Any change to the list puts the selection back on the first row (spec 5.3).
        if found != results {
            selectedIndex = found.isEmpty ? nil : 0
            dropRetry()
        }
        results = found
        section =
            newQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (hasCopied ? .recent : .favorites) : nil
    }

    // MARK: Keys (spec 5.4)

    public func handle(_ key: PanelKey) async -> PanelOutcome {
        if key == .returnKey, let retryKey { return await handle(retryKey) }
        switch key {
        case .up:
            move(by: -1)
            return .stayOpen
        case .down:
            move(by: 1)
            return .stayOpen
        case .escape:
            return .close
        case .openSettings:
            return .closeAndOpenSettings
        case .returnKey, .copyPassword:
            return await copySecret(.password)
        case .copyTOTP:
            return await copySecret(.totp)
        case .copyUsername:
            return await copyUsername()
        case .openURL:
            return openURL()
        }
    }

    private func move(by step: Int) {
        guard let current = selectedIndex else { return }
        let next = min(max(current + step, 0), results.count - 1)
        if next != current { dropRetry() }
        selectedIndex = next
    }

    private enum Secret {
        case password
        case totp
    }

    private func copySecret(_ kind: Secret) async -> PanelOutcome {
        guard !isBusy, let entry = selected?.entry else { return .stayOpen }
        if kind == .totp, !entry.hasTOTP {
            show(.noTOTP)
            return .stayOpen
        }
        isBusy = true
        defer { isBusy = false }
        let startedIn = epoch
        do {
            let value = try await fetch(kind, id: entry.id)
            guard startedIn == epoch else { return .stayOpen }
            guard !value.isEmpty else {
                show(kind == .password ? .noPassword : .noTOTP)
                return .stayOpen
            }
            do {
                try system.copySecret(value)
            } catch {
                // The write began, so the pasteboard was already cleared: not "clipboard unchanged".
                show(.clipboardWriteFailed)
                return .stayOpen
            }
        } catch {
            let failure = footer(for: error, missing: kind == .password ? .noPassword : .noTOTP)
            show(failure)
            if failure == .copyFailed || failure == .timedOut {
                retryKey = kind == .password ? .copyPassword : .copyTOTP
            }
            return .stayOpen
        }
        await recordCopy(id: entry.id, startedIn: startedIn)
        show(kind == .password ? .passwordCopied : .codeCopied)
        return .close
    }

    private func fetch(_ kind: Secret, id: String) async throws -> String {
        switch kind {
        case .password: try await vault.password(for: id)
        case .totp: try await vault.totp(for: id)
        }
    }

    private func copyUsername() async -> PanelOutcome {
        guard !isBusy, let entry = selected?.entry else { return .stayOpen }
        guard let username = entry.username, !username.isEmpty else {
            show(.noUsername)
            return .stayOpen
        }
        isBusy = true
        defer { isBusy = false }
        let startedIn = epoch
        do {
            try system.copyUsername(username)
        } catch {
            show(.clipboardWriteFailed)
            return .stayOpen
        }
        await recordCopy(id: entry.id, startedIn: startedIn)
        show(.usernameCopied)
        scheduleUsernameFooterRevert()
        return .stayOpen
    }

    private func openURL() -> PanelOutcome {
        guard let uri = selected?.entry.uris.first, let url = Self.browserURL(from: uri) else {
            if hasSelection { show(.noURL) }
            return .stayOpen
        }
        system.open(url)
        return .close
    }

    private func recordCopy(id: String, startedIn: Int) async {
        await vault.recordCopy(id: id)
        if startedIn == epoch { hasCopied = true }
    }

    /// Only a fixed footer state ever comes out of an error; its text is never shown.
    private func footer(for error: Error, missing: PanelFooter) -> PanelFooter {
        switch error as? BWError {
        case .noValue: missing
        case .timeout: .timedOut
        case .locked: .locked
        default: .copyFailed
        }
    }

    // MARK: Footer

    /// The selection moved off the failed row: the error and its retry no longer apply.
    private func dropRetry() {
        guard retryKey != nil else { return }
        show(.idle)
    }

    private func show(_ newFooter: PanelFooter) {
        retryKey = nil
        footerRevert?.cancel()
        footerRevert = nil
        footer = newFooter
    }

    private func scheduleUsernameFooterRevert() {
        let sleep = self.sleep
        footerRevert = Task { [weak self] in
            try? await sleep(Self.usernameFooterDuration)
            guard !Task.isCancelled, let self, self.footer == .usernameCopied else { return }
            self.footer = .idle
            self.footerRevert = nil
        }
    }

    /// For tests: returns once a pending footer revert has finished or been cancelled.
    func waitForFooterRevert() async {
        await footerRevert?.value
    }

    // MARK: ⌘O

    /// The URL ⌘O opens for a URI (spec 5.4): http or https only, with a host. A URI without a scheme
    /// ("example.com", "localhost:8080") is read as https, as Bitwarden does. Anything else (javascript:, file:,
    /// ftp:, mailto:) is refused.
    public static func browserURL(from uri: String) -> URL? {
        let text = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let candidate = hasExplicitScheme(text) ? text : "https://" + text
        guard let components = URLComponents(string: candidate),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        return components.url
    }

    /// `scheme://…` or `scheme:…`, except `host:port`, whose "scheme" is followed by digits.
    private static func hasExplicitScheme(_ text: String) -> Bool {
        guard let match = text.firstMatch(of: /^[A-Za-z][A-Za-z0-9+.\-]*:/) else { return false }
        let rest = text[match.range.upperBound...]
        if rest.hasPrefix("//") { return true }
        return rest.firstMatch(of: /^[0-9]+([\/?#]|$)/) == nil
    }
}
