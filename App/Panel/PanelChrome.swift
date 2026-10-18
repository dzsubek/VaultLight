import SwiftUI

/// Pieces shared by the panel's screens (designs 06–16): key chips, the footer bar, buttons, the shake on a wrong
/// secret, and the height report the controller sizes the panel from.

/// A key cap such as "↵" or "⌘C".
struct KeyChip: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.chipFill))
    }
}

/// A key cap with its label, for the footer's right side.
struct KeyHint: View {
    let key: String
    var label: String?

    var body: some View {
        HStack(spacing: 6) {
            KeyChip(key: key)
            if let label { Text(label).font(.system(size: 13)) }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.map { "\(Self.spoken(key)), \($0)" } ?? Self.spoken(key))
    }

    static func spoken(_ key: String) -> String {
        switch key {
        case "↵": "Return"
        case "esc": "Escape"
        default: key
        }
    }
}

/// The colored dot before a footer status.
struct StatusDot: View {
    var color: Color = .secondary

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

/// The 38 pt footer: a status on the left, key hints on the right.
struct FooterBar<Trailing: View>: View {
    let status: String
    var dot: Color = Color.secondary.opacity(0.6)
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                StatusDot(color: dot)
                Text(status)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            HStack(spacing: 14) { trailing }
        }
        .padding(.horizontal, 16)
        .frame(height: PanelMetrics.footerHeight)
        .background(Color.primary.opacity(0.025))
    }
}

/// The teal button with a ↵ glyph (designs 07, 10–12).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.teal.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// The white, hairline-bordered button (Back, Copy).
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.fieldFill.opacity(configuration.isPressed ? 0.7 : 1))
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// A small bordered button inside a footer (design 16 "Try again").
struct CompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.fieldFill.opacity(configuration.isPressed ? 0.7 : 1))
            )
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// "Label ↵", with a spinner while busy.
struct ReturnLabel: View {
    let title: String
    var busy = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if busy {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: "return").font(.system(size: 12, weight: .semibold))
            }
        }
    }
}

/// A short horizontal shake each time `attempts` grows (design 07 "Wrong password").
struct Shake: GeometryEffect {
    var travel: CGFloat = 8
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * 4), y: 0))
    }
}

extension View {
    func shake(_ attempts: Int) -> some View {
        modifier(Shake(animatableData: CGFloat(attempts))).animation(.linear(duration: 0.35), value: attempts)
    }
}

/// A red message with the exclamation mark (design 16).
struct ErrorLine: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.red)
        .accessibilityElement(children: .combine)
    }
}

/// A bordered text field as in the onboarding designs: white fill, teal ring when focused, red when failed.
struct FieldBox: ViewModifier {
    var focused: Bool
    var failed = false
    var monospaced = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 15, design: .monospaced) : .system(size: 15))
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fieldFill))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        failed ? Theme.red : focused ? Theme.teal : Theme.hairline,
                        lineWidth: focused || failed ? 1.5 : 1)
            )
            .shadow(color: (failed ? Theme.red : Theme.teal).opacity(focused || failed ? 0.18 : 0), radius: 3)
    }
}

extension View {
    func fieldBox(focused: Bool, failed: Bool = false, monospaced: Bool = false) -> some View {
        modifier(FieldBox(focused: focused, failed: failed, monospaced: monospaced))
    }
}

/// The height a non-search screen needs, reported to the controller so the panel fits it.
struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    func reportsHeight() -> some View {
        background(
            GeometryReader { proxy in Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height) })
    }
}
