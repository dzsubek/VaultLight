import AppKit
import SwiftUI

/// The Spotlight-style panel (spec 4.2): takes keyboard input without activating the app, so the previous app
/// stays frontmost and the user can paste straight away.
final class SearchPanel: NSPanel {
    /// The panel lost key status, for example after a click outside it (spec 4.3).
    var onResignKey: (() -> Void)?
    /// Escape arrived through the responder chain instead of the key monitor.
    var onCancel: (() -> Void)?

    init(contentSize: CGSize) {
        super.init(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        isFloatingPanel = true
        animationBehavior = .none
        // Best effort: keeps names and usernames out of legacy window capture (ScreenCaptureKit on macOS 15+
        // ignores it). The panel is never restored on relaunch.
        sharingType = .none
        isRestorable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// The field editor sends what is typed to system services: spell checking, completion and substitution stay
    /// off (queries are vault names and hosts, not prose).
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        let editor = super.fieldEditor(createFlag, for: object)
        if let textView = editor as? NSTextView {
            textView.isContinuousSpellCheckingEnabled = false
            textView.isGrammarCheckingEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isAutomaticTextCompletionEnabled = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticLinkDetectionEnabled = false
            textView.isAutomaticDataDetectionEnabled = false
        }
        return editor
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Installs the SwiftUI content inside a rounded, translucent sheet (18 pt corners, hairline edge).
    func install<Content: View>(_ content: Content, opaqueBackground: Bool = false) {
        let sheet = SheetView(frame: CGRect(origin: .zero, size: frame.size))
        sheet.autoresizingMask = [.width, .height]

        let backdrop: NSView
        if opaqueBackground {
            backdrop = SolidBackdropView()
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            backdrop = effect
        }
        backdrop.frame = sheet.bounds
        backdrop.autoresizingMask = [.width, .height]
        sheet.addSubview(backdrop)

        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.frame = sheet.bounds
        hosting.autoresizingMask = [.width, .height]
        sheet.addSubview(hosting)

        contentView = sheet
    }
}

/// Clips to the rounded shape and draws the hairline edge.
private final class SheetView: NSView {
    static let cornerRadius: CGFloat = 18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBorder()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// A flat stand-in for the material, used only where the translucent material can't be captured (DEBUG
/// screenshot mode).
final class SolidBackdropView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor =
                Theme.dynamic(
                    light: NSColor(srgbRed: 0.975, green: 0.975, blue: 0.98, alpha: 1),
                    dark: NSColor(srgbRed: 0.165, green: 0.165, blue: 0.18, alpha: 1)
                ).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
