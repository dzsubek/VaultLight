import VaultLightCore

// The labels of the fixed options in Settings (design 14) and the onboarding unlock step (design 12).

extension AppSettings.ClipboardTimeout {
    var label: String { "\(rawValue) seconds" }
}

extension AppSettings.SyncInterval {
    var label: String {
        switch self {
        case .off: "Off"
        case .fiveMinutes: "Every 5 minutes"
        case .fifteenMinutes: "Every 15 minutes"
        case .sixtyMinutes: "Every hour"
        }
    }
}

extension SessionSettings.StoredMaximumAge {
    var label: String {
        switch self {
        case .oneDay: "1 day"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        }
    }
}

extension SessionSettings.InMemoryLifetime {
    var label: String {
        switch self {
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        case .eightHours: "8 hours"
        }
    }
}

extension SessionSettings.IdleLock {
    var label: String {
        switch self {
        case .off: "Off"
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        }
    }
}
