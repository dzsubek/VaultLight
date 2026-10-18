import AppKit
import SwiftUI

/// Colors for the panel (NOTES.md "Visual direction"): neutral system colors plus one quiet teal.
enum Theme {
    static let teal = Color(
        nsColor: dynamic(
            light: NSColor(srgbRed: 0.0, green: 0.51, blue: 0.56, alpha: 1),
            dark: NSColor(srgbRed: 0.25, green: 0.78, blue: 0.82, alpha: 1)))
    static let selectionFill = Color(
        nsColor: dynamic(
            light: NSColor(srgbRed: 0.0, green: 0.51, blue: 0.56, alpha: 0.18),
            dark: NSColor(srgbRed: 0.25, green: 0.78, blue: 0.82, alpha: 0.24)))
    static let orgPillFill = Color(
        nsColor: dynamic(
            light: NSColor(srgbRed: 0.0, green: 0.51, blue: 0.56, alpha: 0.13),
            dark: NSColor(srgbRed: 0.25, green: 0.78, blue: 0.82, alpha: 0.18)))
    static let amber = Color(
        nsColor: dynamic(
            light: NSColor(srgbRed: 0.70, green: 0.38, blue: 0.0, alpha: 1),
            dark: NSColor(srgbRed: 0.96, green: 0.65, blue: 0.25, alpha: 1)))
    static let red = Color(
        nsColor: dynamic(
            light: NSColor(srgbRed: 0.78, green: 0.13, blue: 0.18, alpha: 1),
            dark: NSColor(srgbRed: 0.90, green: 0.45, blue: 0.43, alpha: 1)))
    static let chipFill = Color.primary.opacity(0.07)
    /// Text fields and secondary buttons: white in light mode, a lifted gray in dark mode.
    static let fieldFill = Color(
        nsColor: dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.08)))
    static let hairline = Color.primary.opacity(0.14)
    /// The selected radio row and the command box (designs 09, 10).
    static let tintedRowFill = Color(
        nsColor: dynamic(
            light: NSColor(srgbRed: 0.0, green: 0.51, blue: 0.56, alpha: 0.16),
            dark: NSColor(srgbRed: 0.25, green: 0.78, blue: 0.82, alpha: 0.18)))
    static let wellFill = Color.primary.opacity(0.05)
    /// Behind the Settings cards and the About window (design 14, 15).
    static let groupedBackground = Color(
        nsColor: dynamic(light: NSColor(white: 0.925, alpha: 1), dark: NSColor(white: 0.17, alpha: 1)))

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// The monogram tile of a row: the name's first letter on a muted hue derived from the name.
enum Monogram {
    private static let hues: [CGFloat] = [0.90, 0.50, 0.02, 0.35, 0.09, 0.75, 0.60, 0.15, 0.45, 0.97]

    /// FNV-1a over the UTF-8 bytes: stable across launches, unlike `hashValue`.
    private static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    private static func hue(for name: String) -> CGFloat {
        hues[Int(fnv1a(name) % UInt32(hues.count))]
    }

    static func letter(for name: String) -> String {
        name.first.map { String($0).uppercased() } ?? "?"
    }

    static func background(for name: String) -> Color {
        let hue = hue(for: name)
        return Color(
            nsColor: Theme.dynamic(
                light: NSColor(hue: hue, saturation: 0.17, brightness: 0.97, alpha: 1),
                dark: NSColor(hue: hue, saturation: 0.40, brightness: 0.36, alpha: 1)))
    }

    static func foreground(for name: String) -> Color {
        let hue = hue(for: name)
        return Color(
            nsColor: Theme.dynamic(
                light: NSColor(hue: hue, saturation: 0.65, brightness: 0.40, alpha: 1),
                dark: NSColor(hue: hue, saturation: 0.30, brightness: 0.95, alpha: 1)))
    }
}
