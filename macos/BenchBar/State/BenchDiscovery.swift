import Foundation
import Observation

/// The scan lives outside the view so navigating between panes keeps results.
@Observable
final class BenchDiscovery {
    private(set) var folder: String
    private(set) var results: [BenchSummary] = []
    private(set) var warnings: [String] = []
    var selected: Set<String> = []
    private(set) var isScanning = false
    private(set) var isAdding = false
    private(set) var hasScanned = false
    private(set) var error: String?
    private(set) var message: String?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    let store: BenchStore

    init(store: BenchStore) {
        self.store = store
        folder = store.settings.scanFolder
    }

    var knownPaths: Set<String> { Set(store.benches.map(\.path)) }
    /// Benches BenchBar already manages: shown as managed, without a checkbox.
    var managedPaths: Set<String> { Set(store.benches.filter { !$0.needsService }.map(\.path)) }
    var selectablePaths: Set<String> { Set(results.map(\.path)).subtracting(managedPaths) }
    var availablePaths: Set<String> { Set(results.map(\.path)).subtracting(knownPaths) }

    /// The scan's warnings as the pane lists them: every "Stopped at N
    /// folders deep: PATH" in one line (a scan of ~ has hundreds), then the
    /// others as they are.
    var warningLines: [String] { Self.warningLines(warnings) }

    static func warningLines(_ warnings: [String]) -> [String] {
        let deep = warnings.filter { $0.hasPrefix("Stopped at ") && $0.contains(" folders deep: ") }
        let others = warnings.filter { !deep.contains($0) }
        guard let first = deep.first else { return others }
        let depth = first.dropFirst("Stopped at ".count).prefix { $0.isNumber }
        let summary = deep.count == 1 ? first
            : "Stopped at \(depth) folders deep in \(deep.count) folders: a bench deeper than that is not found. Choose a folder closer to it."
        return [summary] + others
    }

    /// Adopt Existing Bench: the bench a scan of its own folder found, when
    /// it found one that BenchBar does not manage yet. Its setup plan (the
    /// service files and the ports) is what `benchbar adopt` would do.
    var adoptCandidate: BenchSummary? {
        guard results.count == 1, let bench = results.first, !managedPaths.contains(bench.path) else { return nil }
        return bench
    }

    func hasPortConflict(_ result: BenchSummary) -> Bool {
        let own = Set([result.ports.web, result.ports.socketio, result.ports.redisQueue, result.ports.redisCache])
        let others = results + store.benches.map(\.summary)
        return others.contains { other in
            other.path != result.path && !own.isDisjoint(with: [other.ports.web, other.ports.socketio,
                                                                other.ports.redisQueue, other.ports.redisCache])
        }
    }

    /// `remember`: the folder is the one Find Benches offers next time (an
    /// adopted bench's own folder is not).
    @discardableResult
    func scan(folder: String, remember: Bool = true) -> Task<Void, Never> {
        scanTask?.cancel()
        let token = UUID()
        generation = token
        self.folder = folder
        if remember { store.settings.scanFolder = folder }
        results = []; warnings = []; selected = []
        error = nil; message = nil; hasScanned = false; isScanning = true
        let task = Task { [weak self] in
            guard let self else { return }
            guard let client = store.cliClient else {
                error = "Choose the benchbar command in General before scanning."
                isScanning = false
                return
            }
            do {
                let found = try await client.scan(folder: folder)
                guard !Task.isCancelled, generation == token else { return }
                results = found.benches
                warnings = found.warnings
                selected = availablePaths
                hasScanned = true
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                self.error = error.localizedDescription
            }
            if generation == token { isScanning = false }
        }
        scanTask = task
        return task
    }

    func cancelScan() {
        generation = UUID()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        message = "Scan cancelled."
    }

    func addSelected() async {
        guard !isAdding, !isScanning, let client = store.cliClient else { return }
        let paths = selected.intersection(availablePaths).sorted()
        guard !paths.isEmpty else { return }
        guard store.busyBench == nil else {
            error = "Wait for the current bench operation to finish, then add your selection."
            return
        }
        isAdding = true; error = nil; message = nil
        defer { isAdding = false }
        do {
            try await client.register(benches: paths)
            await store.reloadBenches()
            selected.subtract(paths)
            message = "Added \(paths.count) \(paths.count == 1 ? "bench" : "benches") to BenchBar."
        } catch {
            self.error = error.localizedDescription
        }
    }
}
