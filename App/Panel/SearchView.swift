import SwiftUI
import VaultLightCore

/// The panel's SwiftUI root (designs 01, 02, 03, 05). Fills whatever size the panel has; the controller sizes
/// the panel from the view model's state.
struct SearchView: View {
    let controller: PanelController

    var body: some View {
        Group {
            if controller.content == .unlocked {
                UnlockedView(controller: controller)
            } else {
                // Its own height, reported so the controller fits the panel to it.
                NonSearchView(controller: controller)
                    .fixedSize(horizontal: false, vertical: true)
                    .reportsHeight()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(ContentHeightKey.self) { height in
            Task { @MainActor in controller.reportedHeight = height }
        }
    }
}

private struct UnlockedView: View {
    let controller: PanelController
    @FocusState private var fieldFocused: Bool

    private var model: PanelViewModel { controller.viewModel }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            list
            Divider()
            PanelFooterView(
                footer: model.footer, hasSelection: model.hasSelection, isTOTPAvailable: model.isTOTPAvailable,
                secondsUntilClear: controller.clipboard.secondsUntilClear,
                clearAfter: controller.clipboard.clearAfter, syncStatus: controller.syncStatus,
                onRetry: model.canRetry ? { Task { await controller.retry() } } : nil,
                onSyncNow: { Task { await controller.perform(.syncNow) } })
        }
        .onChange(of: model.spokenSelection) {
            if let spoken = model.spokenSelection { VoiceOver.announce(spoken) }
        }
        .onChange(of: model.footer) {
            if let message = model.footer.message { VoiceOver.announce(message) }
        }
    }

    private var searchField: some View {
        @Bindable var controller = controller
        return HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search vault", text: $controller.queryText)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .tint(Theme.teal)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .accessibilityLabel("Search vault")
                .onChange(of: controller.queryText) {
                    Task { await controller.submitQuery() }
                }
        }
        .padding(.horizontal, 20)
        .frame(height: PanelMetrics.searchHeight)
        .onAppear { fieldFocused = true }
        .onChange(of: controller.openCount) { fieldFocused = true }
    }

    @ViewBuilder private var list: some View {
        if model.results.isEmpty {
            noMatches
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // Lazy: only the visible rows are built, so a keystroke that replaces all 50 stays in budget
                    // (spec 10: 30 ms at 5,000 items).
                    LazyVStack(spacing: 0) {
                        if let section = model.section {
                            Text(section == .recent ? "Recent" : "Favorites")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 5)
                                .frame(height: PanelMetrics.sectionHeaderHeight, alignment: .bottom)
                        }
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                            ResultRow(
                                result: result, query: model.query, isSelected: index == model.selectedIndex,
                                isCopied: index == model.selectedIndex && model.footer.confirmsSecretCopy
                            )
                            .id(result.id)
                            .onTapGesture(count: 2) { Task { await controller.activate(index: index) } }
                            .onTapGesture { controller.select(index: index) }
                            // VoiceOver's default action is the double-click: copy the password (spec 5.3).
                            .accessibilityAction { Task { await controller.activate(index: index) } }
                            .accessibilityHint("Copies the password")
                        }
                    }
                    .padding(.horizontal, PanelMetrics.listPadding)
                    .padding(.top, PanelMetrics.listPadding)
                    .padding(.bottom, PanelMetrics.listPadding - 2)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selectedIndex) {
                    guard let index = model.selectedIndex, model.results.indices.contains(index) else { return }
                    proxy.scrollTo(model.results[index].id)
                }
            }
            .frame(height: PanelMetrics.listHeight(rowCount: model.results.count, hasSection: model.section != nil))
        }
    }

    private var noMatches: some View {
        let trimmed = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 6) {
            if trimmed.isEmpty {
                Text("No logins to show")
                    .font(.system(size: 15, weight: .semibold))
            } else {
                Text("No matches for “\(trimmed)”")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("Search looks at the names, usernames and hosts of your logins.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .frame(height: PanelMetrics.emptyListHeight)
        .accessibilityElement(children: .combine)
    }
}
