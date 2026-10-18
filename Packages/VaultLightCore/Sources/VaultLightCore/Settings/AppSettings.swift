import Foundation

/// Every setting of spec 8, with the spec's defaults. No secrets: the account itself lives in `bw`'s data folder.
public struct AppSettings: Sendable, Equatable {
    public enum ClipboardTimeout: Int, Sendable, CaseIterable {
        case fifteenSeconds = 15
        case thirtySeconds = 30
        case fortyFiveSeconds = 45
        case ninetySeconds = 90

        public var duration: Duration { .seconds(rawValue) }
    }

    /// Minutes between background syncs; `off` stops them.
    public enum SyncInterval: Int, Sendable, CaseIterable {
        case off = 0
        case fiveMinutes = 5
        case fifteenMinutes = 15
        case sixtyMinutes = 60

        /// `nil` when background sync is off.
        public var interval: Duration? { self == .off ? nil : .seconds(rawValue * 60) }
    }

    public var hotKey: HotKeyShortcut
    /// Stored-session maximum age, master password after restart, in-memory lifetime and idle lock.
    public var session: SessionSettings
    public var clipboardTimeout: ClipboardTimeout
    public var backgroundSync: SyncInterval
    public var server: ServerChoice
    /// A custom `bw` path; `nil` auto-detects the pinned Homebrew paths (spec 7.1).
    public var bwPath: String?
    public var launchAtLogin: Bool

    public init(
        hotKey: HotKeyShortcut = .default, session: SessionSettings = SessionSettings(),
        clipboardTimeout: ClipboardTimeout = .fortyFiveSeconds, backgroundSync: SyncInterval = .fifteenMinutes,
        server: ServerChoice = .bitwardenUS, bwPath: String? = nil, launchAtLogin: Bool = false
    ) {
        self.hotKey = hotKey
        self.session = session
        self.clipboardTimeout = clipboardTimeout
        self.backgroundSync = backgroundSync
        self.server = server
        self.bwPath = bwPath
        self.launchAtLogin = launchAtLogin
    }
}

/// The global shortcut (spec 4.1) as Carbon `RegisterEventHotKey` takes it: a virtual key code and Carbon
/// modifier flags. `key` is the label recorded with it, for display.
public struct HotKeyShortcut: Sendable, Equatable {
    // Carbon's `cmdKey`, `shiftKey`, `optionKey` and `controlKey`, without importing Carbon into Core.
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    /// ⌘⇧Space (`kVK_Space` is 49).
    public static let `default` = HotKeyShortcut(keyCode: 49, modifiers: command | shift, key: "Space")

    public let keyCode: UInt32
    public let modifiers: UInt32
    public let key: String

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// A global shortcut needs ⌘, ⌥ or ⌃; ⇧ alone would take a typed character from every app.
    public var hasModifier: Bool { modifiers & (Self.command | Self.option | Self.control) != 0 }

    /// "⌘⇧Space", in the designs' order.
    public var displayString: String {
        let symbols: [(UInt32, String)] = [
            (Self.control, "⌃"), (Self.option, "⌥"), (Self.command, "⌘"), (Self.shift, "⇧"),
        ]
        return symbols.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + key
    }
}

/// Where the account lives (spec 3.2 step 1).
public enum ServerChoice: Sendable, Equatable, Hashable {
    case bitwardenUS
    case bitwardenEU
    /// The address as the user typed it.
    case selfHosted(String)

    static let usURL = "https://vault.bitwarden.com"
    static let euURL = "https://vault.bitwarden.eu"

    /// The URL for `bw config server`: http or https with a host, no credentials, query or fragment. A self-hosted
    /// address without a scheme is read as https. `nil` when the address isn't usable.
    public var url: URL? {
        switch self {
        case .bitwardenUS: return URL(string: Self.usURL)
        case .bitwardenEU: return URL(string: Self.euURL)
        case .selfHosted(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
            guard let components = URLComponents(string: candidate),
                let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
                let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
                components.query == nil, components.fragment == nil
            else { return nil }
            return components.url
        }
    }

    public var displayName: String {
        switch self {
        case .bitwardenUS: "Bitwarden US"
        case .bitwardenEU: "Bitwarden EU"
        case .selfHosted(let text): url?.host() ?? text
        }
    }

    /// The choice for `bw status`'s `serverUrl`; `bw` reports `nil` for its default, Bitwarden US.
    public init(serverURL: String?) {
        guard let serverURL, !serverURL.isEmpty else {
            self = .bitwardenUS
            return
        }
        let normalized = serverURL.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch normalized {
        case Self.usURL: self = .bitwardenUS
        case Self.euURL: self = .bitwardenEU
        default: self = .selfHosted(serverURL)
        }
    }
}
