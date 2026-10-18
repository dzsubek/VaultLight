import Foundation
import Observation

/// The settings, persisted in `UserDefaults` (spec 8). Every change is written at once; there is no Save button.
/// A missing or unreadable value reads as its default, so a fresh install writes nothing until something changes.
@MainActor
@Observable
public final class SettingsStore {
    public var settings: AppSettings {
        didSet {
            if settings != oldValue { save() }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyLabel = "hotKeyLabel"
        static let storedSessionMaximumAge = "storedSessionMaximumAge"
        static let requireMasterPasswordAfterRestart = "requireMasterPasswordAfterRestart"
        static let inMemoryLifetime = "inMemoryLifetime"
        static let idleLock = "idleLock"
        static let clipboardClearSeconds = "clipboardClearSeconds"
        static let backgroundSyncMinutes = "backgroundSyncMinutes"
        static let server = "server"
        static let selfHostedServerURL = "selfHostedServerURL"
        static let bwPath = "bwPath"
        static let launchAtLogin = "launchAtLogin"
    }

    /// Every key this store may write. Nothing else from the settings reaches disk.
    public static let storedKeys: Set<String> = [
        Key.hotKeyCode, Key.hotKeyModifiers, Key.hotKeyLabel, Key.storedSessionMaximumAge,
        Key.requireMasterPasswordAfterRestart, Key.inMemoryLifetime, Key.idleLock, Key.clipboardClearSeconds,
        Key.backgroundSyncMinutes, Key.server, Key.selfHostedServerURL, Key.bwPath, Key.launchAtLogin,
    ]

    /// The `bw --version` check remembered across launches, kept in the same defaults (a path, a date, a size and
    /// a version; no secret). Not a setting, so not in `settings`.
    public var versionMemory: BWVersionMemory { BWVersionMemory(defaults: defaults) }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = Self.load(from: defaults)
    }

    private static func load(from defaults: UserDefaults) -> AppSettings {
        var settings = AppSettings()
        if let code = defaults.object(forKey: Key.hotKeyCode) as? Int,
            let modifiers = defaults.object(forKey: Key.hotKeyModifiers) as? Int,
            let label = defaults.object(forKey: Key.hotKeyLabel) as? String, !label.isEmpty,
            let keyCode = UInt32(exactly: code), let flags = UInt32(exactly: modifiers)
        {
            let shortcut = HotKeyShortcut(keyCode: keyCode, modifiers: flags, key: label)
            if shortcut.hasModifier { settings.hotKey = shortcut }
        }
        func option<T: RawRepresentable>(_ key: String, _ type: T.Type) -> T? {
            (defaults.object(forKey: key) as? T.RawValue).flatMap { T(rawValue: $0) }
        }
        settings.session.storedMaximumAge =
            option(Key.storedSessionMaximumAge, SessionSettings.StoredMaximumAge.self)
            ?? settings.session.storedMaximumAge
        if let flag = defaults.object(forKey: Key.requireMasterPasswordAfterRestart) as? Bool {
            settings.session.requireMasterPasswordAfterRestart = flag
        }
        settings.session.inMemoryLifetime =
            option(Key.inMemoryLifetime, SessionSettings.InMemoryLifetime.self) ?? settings.session.inMemoryLifetime
        settings.session.idleLock = option(Key.idleLock, SessionSettings.IdleLock.self) ?? settings.session.idleLock
        settings.clipboardTimeout =
            option(Key.clipboardClearSeconds, AppSettings.ClipboardTimeout.self) ?? settings.clipboardTimeout
        settings.backgroundSync =
            option(Key.backgroundSyncMinutes, AppSettings.SyncInterval.self) ?? settings.backgroundSync
        switch defaults.object(forKey: Key.server) as? String {
        case "eu": settings.server = .bitwardenEU
        case "selfHosted":
            if let url = defaults.object(forKey: Key.selfHostedServerURL) as? String, !url.isEmpty {
                settings.server = .selfHosted(url)
            }
        default: break
        }
        if let path = defaults.object(forKey: Key.bwPath) as? String, path.hasPrefix("/") { settings.bwPath = path }
        if let flag = defaults.object(forKey: Key.launchAtLogin) as? Bool { settings.launchAtLogin = flag }
        return settings
    }

    private func save() {
        defaults.set(Int(settings.hotKey.keyCode), forKey: Key.hotKeyCode)
        defaults.set(Int(settings.hotKey.modifiers), forKey: Key.hotKeyModifiers)
        defaults.set(settings.hotKey.key, forKey: Key.hotKeyLabel)
        defaults.set(settings.session.storedMaximumAge.rawValue, forKey: Key.storedSessionMaximumAge)
        defaults.set(settings.session.requireMasterPasswordAfterRestart, forKey: Key.requireMasterPasswordAfterRestart)
        defaults.set(settings.session.inMemoryLifetime.rawValue, forKey: Key.inMemoryLifetime)
        defaults.set(settings.session.idleLock.rawValue, forKey: Key.idleLock)
        defaults.set(settings.clipboardTimeout.rawValue, forKey: Key.clipboardClearSeconds)
        defaults.set(settings.backgroundSync.rawValue, forKey: Key.backgroundSyncMinutes)
        switch settings.server {
        case .bitwardenUS:
            defaults.set("us", forKey: Key.server)
            defaults.removeObject(forKey: Key.selfHostedServerURL)
        case .bitwardenEU:
            defaults.set("eu", forKey: Key.server)
            defaults.removeObject(forKey: Key.selfHostedServerURL)
        case .selfHosted(let url):
            defaults.set("selfHosted", forKey: Key.server)
            defaults.set(url, forKey: Key.selfHostedServerURL)
        }
        if let path = settings.bwPath {
            defaults.set(path, forKey: Key.bwPath)
        } else {
            defaults.removeObject(forKey: Key.bwPath)
        }
        defaults.set(settings.launchAtLogin, forKey: Key.launchAtLogin)
    }
}
