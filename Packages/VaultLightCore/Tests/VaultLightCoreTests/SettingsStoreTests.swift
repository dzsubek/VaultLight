import Foundation
import Testing

@testable import VaultLightCore

/// A `UserDefaults` suite of its own per test, removed afterwards; `.standard` is never touched.
final class TestDefaults {
    let suiteName = "com.vaultlight.test.settings.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// What this suite has on disk, without the global and registration domains.
    var stored: [String: Any] { defaults.persistentDomain(forName: suiteName) ?? [:] }
}

@MainActor
@Suite struct SettingsStoreTests {
    @Test func defaultsMatchSpecSection8() {
        let settings = AppSettings()
        #expect(settings.hotKey == .default)
        #expect(settings.hotKey.displayString == "⌘⇧Space")
        #expect(settings.session.storedMaximumAge == .sevenDays)
        #expect(settings.session.requireMasterPasswordAfterRestart)
        #expect(settings.session.inMemoryLifetime == .eightHours)
        #expect(settings.session.idleLock == .fifteenMinutes)
        #expect(settings.clipboardTimeout == .fortyFiveSeconds)
        #expect(settings.clipboardTimeout.duration == .seconds(45))
        #expect(settings.backgroundSync == .fifteenMinutes)
        #expect(settings.backgroundSync.interval == .seconds(15 * 60))
        #expect(settings.server == .bitwardenUS)
        #expect(settings.bwPath == nil)
        #expect(!settings.launchAtLogin)
    }

    @Test func optionsAreTheSpecValues() {
        #expect(AppSettings.ClipboardTimeout.allCases.map(\.duration) == [15, 30, 45, 90].map { .seconds($0) })
        #expect(
            AppSettings.SyncInterval.allCases.map(\.interval) == [nil, 5, 15, 60].map { $0.map { .seconds($0 * 60) } })
        #expect(ServerChoice.bitwardenUS.url?.absoluteString == "https://vault.bitwarden.com")
        #expect(ServerChoice.bitwardenEU.url?.absoluteString == "https://vault.bitwarden.eu")
    }

    @Test func aFreshStoreHasTheDefaultsAndWritesNothing() throws {
        let suite = try TestDefaults()
        let store = SettingsStore(defaults: suite.defaults)
        #expect(store.settings == AppSettings())
        #expect(suite.stored.isEmpty)
    }

    @Test func changesArePersistedAndReadBack() throws {
        let suite = try TestDefaults()
        let changed = Self.everythingChanged
        SettingsStore(defaults: suite.defaults).settings = changed
        #expect(SettingsStore(defaults: suite.defaults).settings == changed)
    }

    @Test func storedKeysAreExactlyTheSettings() throws {
        let suite = try TestDefaults()
        SettingsStore(defaults: suite.defaults).settings = Self.everythingChanged
        #expect(Set(suite.stored.keys) == SettingsStore.storedKeys)
        // The only other keys VaultLight writes: the creation-date hint (`KeychainSessionStore`) and the
        // remembered `bw --version` check (`BWVersionMemory`).
        #expect(
            SettingsStore.storedKeys.isDisjoint(with: [KeychainSessionStore.createdAtHintKey, BWVersionMemory.key]))
    }

    @Test func storedValuesAreOnlyOptionsPathsAndFlags() throws {
        let suite = try TestDefaults()
        SettingsStore(defaults: suite.defaults).settings = Self.everythingChanged
        // Every string on disk is an option name, the shortcut's label, the server address or the `bw` path.
        let allowedStrings: Set<String> = [
            "thirtyDays", "oneHour", "off", "selfHosted", "K", "https://vault.home.arpa", "/Users/tester/bin/bw",
        ]
        for value in suite.stored.values {
            if let text = value as? String {
                #expect(allowedStrings.contains(text), "\(text)")
            } else {
                #expect(value is NSNumber)
            }
        }
    }

    @Test func unreadableValuesFallBackToTheDefaults() throws {
        let suite = try TestDefaults()
        for key in SettingsStore.storedKeys {
            suite.defaults.set("garbage", forKey: key)
        }
        #expect(SettingsStore(defaults: suite.defaults).settings == AppSettings())
    }

    @Test func clearingTheCustomPathRemovesItsKey() throws {
        let suite = try TestDefaults()
        let store = SettingsStore(defaults: suite.defaults)
        store.settings.bwPath = "/Users/tester/bin/bw"
        store.settings.bwPath = nil
        #expect(suite.stored["bwPath"] == nil)
        #expect(SettingsStore(defaults: suite.defaults).settings.bwPath == nil)
    }

    @Test func selfHostedServerKeepsItsURL() throws {
        let suite = try TestDefaults()
        let store = SettingsStore(defaults: suite.defaults)
        store.settings.server = .selfHosted("https://vault.home.arpa")
        #expect(SettingsStore(defaults: suite.defaults).settings.server == .selfHosted("https://vault.home.arpa"))
        #expect(ServerChoice.selfHosted("https://vault.home.arpa").url?.host() == "vault.home.arpa")
        #expect(ServerChoice.selfHosted("vault.home.arpa").url?.absoluteString == "https://vault.home.arpa")
        #expect(ServerChoice.selfHosted("ftp://vault.home.arpa").url == nil)
        #expect(ServerChoice.selfHosted("https://user:pw@vault.home.arpa").url == nil)
        #expect(ServerChoice.selfHosted("").url == nil)
    }

    @Test func serverNamesForTheUI() {
        #expect(ServerChoice.bitwardenUS.displayName == "Bitwarden US")
        #expect(ServerChoice.bitwardenEU.displayName == "Bitwarden EU")
        #expect(ServerChoice.selfHosted("https://vault.home.arpa").displayName == "vault.home.arpa")
        #expect(ServerChoice(serverURL: "https://vault.bitwarden.eu") == .bitwardenEU)
        #expect(ServerChoice(serverURL: nil) == .bitwardenUS)
        #expect(ServerChoice(serverURL: "https://vault.home.arpa/") == .selfHosted("https://vault.home.arpa/"))
    }

    @Test func shortcutsDisplayLikeTheDesign() {
        let shortcut = HotKeyShortcut(
            keyCode: 40, modifiers: HotKeyShortcut.control | HotKeyShortcut.option | HotKeyShortcut.command,
            key: "K")
        #expect(shortcut.displayString == "⌃⌥⌘K")
        #expect(!HotKeyShortcut(keyCode: 40, modifiers: 0, key: "K").hasModifier)
        #expect(HotKeyShortcut.default.hasModifier)
    }

    private static var everythingChanged: AppSettings {
        var settings = AppSettings()
        settings.hotKey = HotKeyShortcut(
            keyCode: 40, modifiers: HotKeyShortcut.option | HotKeyShortcut.command, key: "K")
        settings.session = SessionSettings(
            storedMaximumAge: .thirtyDays, requireMasterPasswordAfterRestart: false, inMemoryLifetime: .oneHour,
            idleLock: .off)
        settings.clipboardTimeout = .ninetySeconds
        settings.backgroundSync = .off
        settings.server = .selfHosted("https://vault.home.arpa")
        settings.bwPath = "/Users/tester/bin/bw"
        settings.launchAtLogin = true
        return settings
    }
}
