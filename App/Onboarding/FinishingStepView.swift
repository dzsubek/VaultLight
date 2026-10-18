import SwiftUI
import VaultLightCore

// MARK: Finishing (design 12 state 2)

struct FinishingStepView: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(title: "Getting your vault ready", subtitle: "This takes a few seconds the first time.")
            VStack(alignment: .leading, spacing: 10) {
                let checklist = model.checklist
                let states = rowStates(checklist)
                row("Signed in", detail: model.configuredServer?.displayName, state: .done)
                row("Vault unlocked", detail: nil, state: states[0])
                if checklist.sessionSaved == false {
                    row("Session not saved to the Keychain", detail: "master password next time", state: .warning)
                } else {
                    row("Session saved to the Keychain", detail: "Touch ID next time", state: states[1])
                }
                row("Building the search index", detail: checklist.logins.map { "\($0) logins" }, state: states[2])
            }
            .padding(.top, 16)
            Text("Search opens by itself when the index is ready.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 16)
        }
        .stepInsets()
    }

    private enum RowState {
        case done, working, waiting, warning

        var spoken: String {
            switch self {
            case .done: "Done"
            case .working: "In progress"
            case .waiting: "Waiting"
            case .warning: "Warning"
            }
        }
    }

    /// Done rows get a check; the first one not done spins; the rest wait.
    private func rowStates(_ checklist: OnboardingModel.Checklist) -> [RowState] {
        let done = [checklist.vaultUnlocked, checklist.sessionSaved != nil, checklist.indexBuilt]
        var states: [RowState] = []
        var spinning = false
        for isDone in done {
            if isDone {
                states.append(.done)
            } else if !spinning {
                states.append(.working)
                spinning = true
            } else {
                states.append(.waiting)
            }
        }
        return states
    }

    private func row(_ title: String, detail: String?, state: RowState) -> some View {
        HStack(spacing: 10) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                case .warning:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.amber)
                case .working:
                    ProgressView().controlSize(.small)
                case .waiting:
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 17))
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
            Text(title).font(.system(size: 14))
            if let detail { Text(detail).font(.system(size: 14)).foregroundStyle(.tertiary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(state.spoken)
    }
}
