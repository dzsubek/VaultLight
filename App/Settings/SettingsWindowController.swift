import AppKit
import SwiftUI

/// The Settings window (spec 8, design 14): General, Security and Vault as toolbar tabs. Changes apply at once.
/// Opening it brings VaultLight to the front, so its menu bar shows (NOTES.md Screen 14).
@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init(model: AppModel) {
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let hosting = NSHostingController(
                rootView: Self.page(tab, model: model).frame(width: 620).fixedSize(horizontal: false, vertical: true))
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = tab.title
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        super.init(window: window)
        window.center()
    }

    @ViewBuilder
    private static func page(_ tab: SettingsTab, model: AppModel) -> some View {
        switch tab {
        case .general: GeneralSettingsView(model: model)
        case .security: SecuritySettingsView(model: model)
        case .vault: VaultSettingsView(model: model)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows the window at `tab`, or at the last tab used.
    func show(tab: SettingsTab?) {
        if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
        /// For screenshots: the window frame including the title bar and toolbar.
        func select(_ tab: SettingsTab) {
            tabs.selectedTabViewItemIndex = tab.rawValue
        }
    #endif
}

extension SettingsTab {
    var title: String {
        switch self {
        case .general: "General"
        case .security: "Security"
        case .vault: "Vault"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .security: "lock"
        case .vault: "server.rack"
        }
    }
}

// MARK: Layout pieces (design 14)

/// A titled card of rows with an optional note under it.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 5)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                Group { content }
            }
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.fieldFill))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline))
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 5)
                    .padding(.top, 2)
            }
        }
    }
}

/// One row: a label (with an optional gray or red line under it) and its control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var subtitleIsError = false
    var divider = false
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            if divider { Divider().padding(.leading, 12) }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(subtitleIsError ? Theme.red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 12)
            .padding(.vertical, subtitle == nil ? 10 : 8)
            .frame(minHeight: 42)
        }
    }
}

/// The page around the sections.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) { content }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.groupedBackground)
    }
}
