import Foundation
import VaultLightCore

/// What the panel shows. Until the designed locked, onboarding and error states exist, these are small interim
/// views (`LockedView`). Lives in the App; the vault states themselves come from Core's `VaultState`.
enum PanelContent: Equatable {
    /// The vault state is being read.
    case checking
    case unlocked
    /// "Touch ID to unlock". `canceled` once the user dismissed the sheet (Return retries).
    case touchID(canceled: Bool)
    case masterPassword(failed: Bool, busy: Bool)
    case needsOnboarding
    case problem(PanelProblem)
}

/// A fixed message per failure; the raw error text is never shown.
enum PanelProblem: Equatable {
    case cliMissing
    case cliTooOld
    case cliUnsafe
    case generic

    var message: String {
        switch self {
        case .cliMissing: "Bitwarden CLI not found. Install it with brew install bitwarden-cli."
        case .cliTooOld: "Bitwarden CLI is too old. Run brew upgrade bitwarden-cli."
        case .cliUnsafe: "The bw binary is not safe to use."
        case .generic: "Something went wrong."
        }
    }

    init(_ error: any Error) {
        switch error as? BWError {
        case .notInstalled: self = .cliMissing
        case .tooOld: self = .cliTooOld
        case .unsafeBinary: self = .cliUnsafe
        default: self = .generic
        }
    }
}

/// The panel's fixed dimensions (designs 01, 02, 05; NOTES.md "Visual direction").
enum PanelMetrics {
    static let width: CGFloat = 680
    static let searchHeight: CGFloat = 60
    static let dividerHeight: CGFloat = 1
    static let rowHeight: CGFloat = 50
    static let sectionHeaderHeight: CGFloat = 25
    static let listPadding: CGFloat = 8
    static let maxVisibleRows = 8
    static let footerHeight: CGFloat = 38
    /// The "no matches" area is as tall as a short list, so the panel doesn't collapse to the field.
    static let emptyListHeight: CGFloat = 200
    static let lockedBodyHeight: CGFloat = 90

    static func listHeight(rowCount: Int, hasSection: Bool) -> CGFloat {
        guard rowCount > 0 else { return emptyListHeight }
        let rows = CGFloat(min(rowCount, maxVisibleRows)) * rowHeight
        return (hasSection ? sectionHeaderHeight : 0) + rows + listPadding * 2 - 2
    }

    static func height(unlockedRowCount rowCount: Int, hasSection: Bool) -> CGFloat {
        searchHeight + dividerHeight + listHeight(rowCount: rowCount, hasSection: hasSection) + dividerHeight
            + footerHeight
    }

    static var lockedHeight: CGFloat { searchHeight + dividerHeight + lockedBodyHeight }
}
