import SwiftUI

/// Why a bench is not running, in one line, and the one thing to do next.
/// Pure: the state, the stop reason, whether the bench is managed and
/// whether a port conflict was found go in, so every case is a unit test.
/// The actions are the ones the app already has (BenchControls decides
/// whether Start works); nothing here calls the CLI.
nonisolated struct BenchGuidance: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case start, viewHealth, reviewPortConflict, repair, setUpManagement

        static let allTitles = [Action.start, .viewHealth, .reviewPortConflict, .repair, .setUpManagement].map(\.title)

        var title: String {
            switch self {
            case .start: "Start"
            case .viewHealth: "View Health…"
            case .reviewPortConflict: "Review Port Conflict…"
            case .repair: "Repair…"
            case .setUpManagement: "Set Up Management…"
            }
        }
    }

    var reason: String
    var action: Action?

    /// nil while the bench runs or while an action is under way: nothing to say.
    static func make(state: BenchState, reason: StopReason?, needsService: Bool, portConflict: Bool, pending: Bool = false) -> BenchGuidance? {
        if pending { return nil }
        if needsService {
            return BenchGuidance(reason: "BenchBar does not manage this bench yet, so it cannot start it.", action: .setUpManagement)
        }
        if portConflict {
            return BenchGuidance(reason: "Another program holds one of its ports.", action: .reviewPortConflict)
        }
        switch state {
        case .running, .starting:
            return nil
        case .crashed:
            return BenchGuidance(reason: "It crashed and launchd is restarting it.", action: .viewHealth)
        case .paused:
            switch reason {
            case .broken: return BenchGuidance(reason: "Its environment is broken, so automatic restarts are paused.", action: .repair)
            case .portConflict: return BenchGuidance(reason: "Another program holds one of its ports.", action: .reviewPortConflict)
            case .manual: return BenchGuidance(reason: "You stopped it.", action: .start)
            default: return BenchGuidance(reason: "It crashed three times in ten minutes, so restarts are paused.", action: .viewHealth)
            }
        case .stopped:
            switch reason {
            case .broken: return BenchGuidance(reason: "Its environment is broken, so it cannot start.", action: .repair)
            case .portConflict: return BenchGuidance(reason: "Another program held one of its ports when it started.", action: .reviewPortConflict)
            case .manual: return BenchGuidance(reason: "You stopped it.", action: .start)
            default: return BenchGuidance(reason: "It has not been started yet.", action: .start)
            }
        case .unknown:
            return nil
        }
    }
}

extension BenchModel {
    var guidance: BenchGuidance? {
        BenchGuidance.make(state: state, reason: machine.stopReason, needsService: needsService,
                           portConflict: portConflict != nil, pending: pending != nil)
    }
}

/// The reason under a bench's state, with the next action as a link.
struct GuidanceLine: View {
    let guidance: BenchGuidance
    var enabled = true
    let perform: (BenchGuidance.Action) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
            Text(guidance.reason).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = guidance.action {
                Button(action.title) { perform(action) }
                    .buttonStyle(.link).font(.caption)
                    .disabled(!enabled)
            }
        }
    }
}

/// An empty list that says what it is for and offers its one action: a
/// compact ContentUnavailableView for the sections of a form.
struct EmptyStateBlock: View {
    let symbol: String
    let title: String
    let line: String
    var actions: [(title: String, run: () -> Void)] = []
    var disabled = false

    var body: some View {
        VStack(spacing: WindowMetrics.rowSpacing) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.headline)
            Text(line).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: WindowMetrics.rowSpacing) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button(action.title, action: action.run).disabled(disabled)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, WindowMetrics.spacing)
        .accessibilityElement(children: .contain)
    }
}
