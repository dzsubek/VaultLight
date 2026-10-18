import VaultLightCore

// The labels of the fixed options in Settings (design 14) and the onboarding unlock step (design 12).

extension AppSettings.ClipboardTimeout {
    var label: String { String(localized: "\(rawValue) seconds") }
}

extension AppSettings.SyncInterval {
    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .fiveMinutes: String(localized: "Every 5 minutes")
        case .fifteenMinutes: String(localized: "Every 15 minutes")
        case .sixtyMinutes: String(localized: "Every hour")
        }
    }
}

extension SessionSettings.StoredMaximumAge {
    var label: String {
        switch self {
        case .oneDay: String(localized: "1 day")
        case .sevenDays: String(localized: "7 days")
        case .thirtyDays: String(localized: "30 days")
        }
    }
}

extension SessionSettings.InMemoryLifetime {
    var label: String {
        switch self {
        case .fifteenMinutes: String(localized: "15 minutes")
        case .oneHour: String(localized: "1 hour")
        case .eightHours: String(localized: "8 hours")
        }
    }
}

extension SessionSettings.IdleLock {
    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .fiveMinutes: String(localized: "5 minutes")
        case .fifteenMinutes: String(localized: "15 minutes")
        case .thirtyMinutes: String(localized: "30 minutes")
        }
    }
}
