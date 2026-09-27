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
    var selectablePaths: Set<String> { Set(results.map(\.path)) }
    var availablePaths: Set<String> { Set(results.map(\.path)).subtracting(knownPaths) }

    func hasPortConflict(_ result: BenchSummary) -> Bool {
        let own = Set([result.ports.web, result.ports.socketio, result.ports.redisQueue, result.ports.redisCache])
        let others = results + store.benches.map(\.summary)
        return others.contains { other in
            other.path != result.path && !own.isDisjoint(with: [other.ports.web, other.ports.socketio,
                                                                other.ports.redisQueue, other.ports.redisCache])
        }
    }

    @discardableResult
    func scan(folder: String) -> Task<Void, Never> {
        scanTask?.cancel()
        let token = UUID()
        generation = token
        self.folder = folder
        store.settings.scanFolder = folder
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

/// Uses the existing service-only adoption command, with a preview first.
@Observable
final class AdoptionRun: Identifiable {
    enum Phase: Equatable { case planning, review, running, finished, failed(String) }
    private(set) var phase: Phase = .planning
    private(set) var output = ""
    let bench: BenchModel
    private let store: BenchStore

    init(bench: BenchModel, store: BenchStore) { self.bench = bench; self.store = store }

    private func checkStopped(_ client: CLIClient) async throws(CLIError) {
        let status = try await client.status(bench: bench.path)
        if status.processesRunning == true || status.state == .running || status.state == .starting {
            throw CLIError.failed(command: "adopt", exitCode: 1,
                                  message: "Stop this bench and disable its previous automatic startup before setting up BenchBar management. Its processes are still running.")
        }
    }

    func loadPlan() async {
        guard let client = store.cliClient else { phase = .failed("The benchbar command is unavailable."); return }
        do {
            try await checkStopped(client)
            output = try await client.adopt(bench: bench.path, preview: true).stdout
            phase = .review
        } catch { phase = .failed(error.localizedDescription) }
    }

    func run() async {
        guard phase == .review else { return }
        phase = .running
        let error = await store.runChange("Set up management", on: bench) { client throws(CLIError) in
            try await self.checkStopped(client)
            let result = try await client.adopt(bench: self.bench.path, preview: false)
            self.output = result.stdout + result.stderr
        }
        if let error { phase = .failed(error) }
        else if store.benches.first(where: { $0.path == bench.path })?.summary.serviceInstalled == true { phase = .finished }
        else { phase = .failed("Setup returned, but the service was not found. Review the output and run Doctor.") }
    }
}
