import Foundation

/// What the BenchBar window's sidebar lists, built from the bench list: a
/// row per bench with its sites beneath. Pure, so zero, one and several
/// benches (and benches with the same name) are unit tests.
nonisolated struct SidebarModel: Equatable, Sendable {
    nonisolated struct Site: Equatable, Sendable, Identifiable {
        var name: String
        var isDefault: Bool
        var id: String { name }
    }

    nonisolated struct Row: Equatable, Sendable, Identifiable {
        var path: String
        var name: String
        /// The folder the bench is in, when another bench has the same name.
        var hint: String?
        var state: BenchState
        var isBusy: Bool
        var sites: [Site]
        /// Why it is not running and what to do (BenchGuidance), for the tooltip.
        var guidance: String?
        /// The state in words ("Running", "Crashed (exit 1), restarting"), for VoiceOver:
        /// the dot beside the name says it by colour only.
        var statusText: String
        var id: String { path }
        /// What VoiceOver reads for the row: the state, and the guidance when there is one.
        var accessibilityValue: String { [statusText, guidance].compactMap { $0 }.joined(separator: ". ") }
    }

    /// The bench fields the sidebar needs.
    nonisolated struct Input: Equatable, Sendable {
        var path: String
        var name: String
        var state: BenchState
        var isBusy: Bool
        var sites: [Site]
        var guidance: BenchGuidance? = nil
        /// The popover's headline for the state; the plain state name when not given.
        var statusText: String? = nil
    }

    var benches: [Row]
    /// "On your network" is listed only while the lan-rooms lab is on.
    var showsNetwork: Bool

    init(_ inputs: [Input], showsNetwork: Bool = false) {
        self.showsNetwork = showsNetwork
        // one pass for the names, not a scan of every bench per bench
        let nameCounts = Dictionary(inputs.map { ($0.name, 1) }, uniquingKeysWith: +)
        benches = inputs.map { input in
            let twins = nameCounts[input.name, default: 0] > 1
            return Row(path: input.path, name: input.name,
                       hint: twins ? URL(fileURLWithPath: input.path).deletingLastPathComponent().lastPathComponent : nil,
                       state: input.state, isBusy: input.isBusy, sites: input.sites,
                       guidance: input.guidance.map { [$0.reason, $0.action.map { String(localized: "Next: \($0.title)") }].compactMap { $0 }.joined(separator: " ") },
                       statusText: input.statusText ?? BenchText.headline(input.state, reason: nil, exitCode: nil))
        }
    }

    var isEmpty: Bool { benches.isEmpty }

    /// Shown instead of the bench rows.
    static let emptyText = String(localized: "No bench yet")
}

/// What a sidebar row opens.
nonisolated enum SidebarItem: Hashable, Sendable {
    case bench(String)
    /// A bench's site: opens that bench's Sites tab.
    case site(bench: String, name: String)
    case profiles
    case discovery
    case history
    case network
}

extension SidebarModel {
    @MainActor init(benches: [BenchModel], showsNetwork: Bool = false) {
        self.init(benches.map { bench in
            Input(path: bench.path, name: bench.name, state: bench.state, isBusy: bench.isBusy,
                  sites: bench.siteRows.map { Site(name: $0.name, isDefault: $0.isDefault) }, guidance: bench.guidance,
                  statusText: BenchText.headline(bench.state, reason: bench.machine.stopReason, exitCode: bench.status?.lastExitCode,
                                                 ready: bench.status?.ready))
        }, showsNetwork: showsNetwork)
    }
}
