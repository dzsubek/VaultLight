import Foundation
import VaultLightCore

/// What the panel shows: Core's `PanelScreen` (spec 3.1, 7.4) plus the UI-only flags of the locked screens.
enum PanelContent: Equatable {
    /// The vault state is being read.
    case checking
    case unlocked
    /// "Touch ID to unlock" (design 06). `canceled` once the user dismissed the sheet (Return retries).
    case touchID(canceled: Bool)
    /// The master password field (design 07). `attempts` counts wrong passwords, for the shake.
    case masterPassword(MasterPasswordReason, attempts: Int, busy: Bool)
    /// Onboarding (designs 10–12); its step lives in `OnboardingModel`.
    case onboarding
    /// `bw` is missing, too old or unsafe (designs 09, 16).
    case setupProblem(SetupProblem)
    case failure(PanelFailure)

    init(_ screen: PanelScreen) {
        switch screen {
        case .checking: self = .checking
        case .search: self = .unlocked
        case .touchID: self = .touchID(canceled: false)
        case .masterPassword(let reason): self = .masterPassword(reason, attempts: 0, busy: false)
        case .onboarding: self = .onboarding
        case .setupProblem(let problem): self = .setupProblem(problem)
        case .failure(let failure): self = .failure(failure)
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
    /// Until a non-search screen reports its own height.
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
