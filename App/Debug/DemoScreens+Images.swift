#if DEBUG
    import AppKit
    import SwiftUI
    import VaultLightCore

    extension DemoScreens {
        // MARK: Composite images

        /// The real menu-bar countdown image (`MenuBarIcon`) on a plain strip the size of the design's
        /// (1040×52 pt). The system menu bar itself can't be captured without screen-recording permission, so the
        /// clock and other system items are not drawn.
        static func menuBarStrip(appearance: NSAppearance?) -> NSView {
            let strip = NSView(frame: NSRect(x: 0, y: 0, width: 1040, height: 52))
            strip.appearance = appearance
            strip.wantsLayer = true
            strip.layer?.backgroundColor = backdrop(appearance).cgColor
            let image = MenuBarIcon.countdown(symbolName: "key.horizontal", seconds: 45)
            let icon = NSImageView(image: image)
            icon.contentTintColor = .labelColor
            let origin = NSPoint(
                x: strip.bounds.width - 260 - image.size.width, y: (strip.bounds.height - image.size.height) / 2)
            icon.frame = NSRect(origin: origin, size: image.size)
            strip.addSubview(icon)
            attachWindow(to: strip)
            return strip
        }

        /// The four footer states of design 16 state 5, each drawn by the real `PanelFooterView`.
        static func footerStates(appearance: NSAppearance?) -> NSView {
            let footers = VStack(alignment: .leading, spacing: 10) {
                footer("No one-time code (⌘T on an item without TOTP)", .noTOTP)
                footer("Copy failed", .copyFailed, retry: true)
                footer("CLI timeout", .timedOut, retry: true)
                footer("Code copied (⌘T)", .codeCopied, seconds: 45)
            }
            .padding(24)
            .frame(width: PanelMetrics.width + 48)
            return hostedView(footers, appearance: appearance)
        }

        static func footer(_ caption: String, _ state: PanelFooter, retry: Bool = false, seconds: Int? = nil)
            -> some View
        {
            VStack(alignment: .leading, spacing: 6) {
                Text(caption).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                PanelFooterView(
                    footer: state, hasSelection: true, isTOTPAvailable: state != .noTOTP, secondsUntilClear: seconds,
                    clearAfter: .seconds(45), onRetry: retry ? {} : nil
                )
                .frame(width: PanelMetrics.width)
                .background(SheetBackground())
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
            }
        }

        /// The menu drawn from the real `NSMenuItem`s `StatusItemController` builds (an open `NSMenu` can't be
        /// captured in-process).
        static func menuSnapshot(model: AppModel, appearance: NSAppearance?) -> NSView {
            let items = StatusItemController.items(model: model, target: nil)
            return hostedView(MenuSnapshot(items: items).padding(24), appearance: appearance)
        }

        static func hostedView<Content: View>(_ content: Content, appearance: NSAppearance?) -> NSView {
            let hosting = NSHostingView(rootView: content.background(Color(nsColor: backdrop(appearance))))
            hosting.appearance = appearance
            hosting.frame.size = hosting.fittingSize
            attachWindow(to: hosting)
            hosting.layoutSubtreeIfNeeded()
            return hosting
        }

        static func backdrop(_ appearance: NSAppearance?) -> NSColor {
            appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.13, alpha: 1)
                : NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1)
        }

        /// A window gives the views an effective appearance; it is never shown.
        static func attachWindow(to view: NSView) {
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: true)
            window.appearance = view.appearance
            window.contentView = view
        }

        // MARK: Capture

        static func png(of panel: NSPanel) -> Data? {
            panel.contentView.flatMap(png(of:))
        }

        /// The whole window, title bar and toolbar included: the frame view above the content view.
        static func png(ofWindow window: NSWindow) -> Data? {
            (window.contentView?.superview ?? window.contentView).flatMap(png(of:))
        }

        static func png(of view: NSView) -> Data? {
            let size = view.bounds.size
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return nil }
            rep.size = size
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])
        }
    }
#endif
