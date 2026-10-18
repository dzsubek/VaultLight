import AppKit

/// The menu-bar image (design 04 menu bar): the glyph alone at rest; while a copied secret is pending, a capsule
/// with the glyph and the seconds left until the clipboard clears. Template images, so the menu bar tints them for
/// light, dark and highlighted states, and the capsule takes the menu bar's own color instead of the accent.
enum MenuBarIcon {
    static let height: CGFloat = 22
    private static var font: NSFont { .monospacedDigitSystemFont(ofSize: 13, weight: .medium) }
    private static var symbolConfiguration: NSImage.SymbolConfiguration { .init(pointSize: 13, weight: .medium) }

    static func resting(symbolName: String, description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    /// The glyph with an amber warning badge (design 13 state 3). Not a template, so the badge keeps its color; the
    /// glyph is drawn in the label color of the appearance it is drawn for.
    static func badged(symbolName: String, description: String) -> NSImage {
        let badgeConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            .applying(.init(paletteColors: [.systemOrange]))
        let glyph = symbol(symbolName)
        let badge = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(badgeConfiguration)
        let glyphWidth = glyph?.size.width ?? 16
        let badgeWidth = badge?.size.width ?? 10
        let size = NSSize(width: ceil(glyphWidth + 3 + badgeWidth), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            if let glyph {
                let tinted = NSImage(size: glyph.size, flipped: false) { glyphRect in
                    glyph.draw(in: glyphRect)
                    NSColor.labelColor.set()
                    glyphRect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(
                    in: NSRect(origin: NSPoint(x: 0, y: (rect.height - glyph.size.height) / 2), size: glyph.size))
            }
            if let badge {
                badge.draw(
                    in: NSRect(
                        origin: NSPoint(x: glyphWidth + 3, y: (rect.height - badge.size.height) / 2), size: badge.size))
            }
            return true
        }
        image.accessibilityDescription = description
        return image
    }

    static func countdown(symbolName: String, seconds: Int) -> NSImage {
        let label = "\(seconds)s"
        // Wide enough for two digits, so the item doesn't shift when the count drops below 10.
        let labelWidth = max(textSize(label).width, textSize("88s").width)
        let symbolWidth = symbol(symbolName)?.size.width ?? 0
        let padding: CGFloat = 7
        let gap: CGFloat = 5
        let size = NSSize(width: ceil(padding + symbolWidth + gap + labelWidth + padding), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            if let symbol = symbol(symbolName) {
                let origin = NSPoint(x: padding, y: (rect.height - symbol.size.height) / 2)
                symbol.draw(in: NSRect(origin: origin, size: symbol.size))
            }
            let text = attributed(label)
            let textOrigin = NSPoint(x: padding + symbolWidth + gap, y: (rect.height - text.size().height) / 2)
            text.draw(at: textOrigin)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfiguration)
    }

    private static func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
    }

    private static func textSize(_ text: String) -> NSSize {
        attributed(text).size()
    }
}
