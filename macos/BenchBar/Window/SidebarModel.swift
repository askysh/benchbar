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
        var id: String { path }
    }

    /// The bench fields the sidebar needs.
    nonisolated struct Input: Equatable, Sendable {
        var path: String
        var name: String
        var state: BenchState
        var isBusy: Bool
        var sites: [Site]
        var guidance: BenchGuidance? = nil
    }

    var benches: [Row]

    init(_ inputs: [Input]) {
        benches = inputs.map { input in
            let twins = inputs.filter { $0.name == input.name }.count > 1
            return Row(path: input.path, name: input.name,
                       hint: twins ? URL(fileURLWithPath: input.path).deletingLastPathComponent().lastPathComponent : nil,
                       state: input.state, isBusy: input.isBusy, sites: input.sites,
                       guidance: input.guidance.map { [$0.reason, $0.action.map { "Next: \($0.title)" }].compactMap { $0 }.joined(separator: " ") })
        }
    }

    var isEmpty: Bool { benches.isEmpty }

    /// Shown instead of the bench rows.
    static let emptyText = "No bench yet"
}

/// What a sidebar row opens.
nonisolated enum SidebarItem: Hashable, Sendable {
    case bench(String)
    /// A bench's site: opens that bench's Sites tab.
    case site(bench: String, name: String)
    case profiles
    case discovery
}

extension SidebarModel {
    @MainActor init(benches: [BenchModel]) {
        self.init(benches.map { bench in
            Input(path: bench.path, name: bench.name, state: bench.state, isBusy: bench.isBusy,
                  sites: bench.siteRows.map { Site(name: $0.name, isDefault: $0.isDefault) }, guidance: bench.guidance)
        })
    }
}
