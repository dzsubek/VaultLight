import AppKit

/// Spoken feedback for changes that happen away from the focused element (spec 10): focus stays in the search field,
/// so selection moves and footer results are announced instead.
@MainActor
enum VoiceOver {
    static func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let app = NSApp else { return }
        NSAccessibility.post(
            element: app, notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }
}
