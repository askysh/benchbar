import Foundation
import Observation

/// The experiments the app knows how to switch a feature for. The CLI lists
/// more or fewer; `Labs.entries` keeps every name it sends.
enum Lab: String, CaseIterable, Sendable {
    case lanRooms = "lan-rooms"
    case quickSwitch = "quick-switch"
}

/// How `Labs` reads and writes the flags, so tests need no CLI.
nonisolated struct LabsLoader: Sendable {
    var load: @Sendable () async throws -> [LabEntry]
    var set: @Sendable (_ name: String, _ on: Bool) async throws -> Void

    /// Not wired yet (before the CLI is known): reports the CLI as missing.
    static let unavailable = LabsLoader(
        load: { throw CLIError.notFound(searched: []) },
        set: { _, _ in throw CLIError.notFound(searched: []) })

    /// The real CLI; `client` is asked on every call, so a changed CLI path counts.
    static func cli(_ client: @escaping @Sendable () async -> CLIClient?) -> LabsLoader {
        LabsLoader(
            load: {
                guard let client = await client() else { throw CLIError.notFound(searched: []) }
                return try await client.labs()
            },
            set: { name, on in
                guard let client = await client() else { throw CLIError.notFound(searched: []) }
                try await client.labsSet(name: name, on: on)
            })
    }
}

/// Settings > Labs. The CLI is the source of truth (its LABS key), so the CLI,
/// MCP and the app agree: the app keeps no copy of the flags beyond what the
/// last `labs list` said.
@Observable @MainActor
final class Labs {
    enum Availability: Equatable { case unknown, available, unsupported }

    static let shared = Labs()

    private(set) var entries: [LabEntry] = []
    private(set) var availability: Availability = .unknown
    /// Names with a CLI call running: their toggle is disabled.
    private(set) var busy: Set<String> = []
    /// The last failure per name, shown under its row.
    private(set) var errors: [String: String] = [:]

    /// A feature hears of a flip here (unregister a hotkey, hide a pane).
    @ObservationIgnored var onChange: ((Lab, Bool) -> Void)?
    @ObservationIgnored var loader: LabsLoader
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var refreshing = false
    /// Calls closer together than this reuse the last answer.
    static let minimumInterval: TimeInterval = 5

    init(loader: LabsLoader = .unavailable, now: @escaping () -> Date = Date.init) {
        self.loader = loader
        self.now = now
    }

    func isOn(_ lab: Lab) -> Bool {
        entries.first { $0.name == lab.rawValue }?.enabled ?? false
    }

    /// One CLI call; skipped when the last one was under 5 s ago or one is running.
    func refresh(force: Bool = false) async {
        if refreshing { return }
        if !force, let last = lastRefresh, now().timeIntervalSince(last) < Self.minimumInterval { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let fresh = try await loader.load()
            lastRefresh = now()
            availability = .available
            apply(fresh)
        } catch {
            lastRefresh = now()
            // a CLI without `labs` exits non zero; anything else is no verdict
            if case CLIError.failed = error {
                availability = .unsupported
                apply([])
            }
        }
    }

    func set(_ lab: Lab, on: Bool) async throws {
        try await set(name: lab.rawValue, on: on)
    }

    /// For a name the app has no case for (a lab shown only in Settings).
    func set(name: String, on: Bool) async throws {
        guard !busy.contains(name) else { return }
        busy.insert(name)
        errors[name] = nil
        defer { busy.remove(name) }
        do {
            try await loader.set(name, on)
        } catch {
            errors[name] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if case CLIError.failed(_, _, let message) = error, !message.isEmpty { errors[name] = message }
            throw error
        }
        var next = entries
        if let index = next.firstIndex(where: { $0.name == name }) { next[index].enabled = on }
        apply(next)
    }

    private func apply(_ fresh: [LabEntry]) {
        let before = Dictionary(Lab.allCases.map { ($0, isOn($0)) }) { first, _ in first }
        entries = fresh
        for lab in Lab.allCases where before[lab] != isOn(lab) { onChange?(lab, isOn(lab)) }
    }
}
