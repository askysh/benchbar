import Foundation
import Observation

/// One bench as the UI sees it.
@Observable
final class BenchModel: Identifiable {
    let path: String
    var summary: BenchSummary
    var machine = BenchStateMachine()
    /// The last failed action or refresh, shown once in the popover.
    var lastError: String?
    var doctor: DoctorReport?
    var doctorError: String?
    var isRunningDoctor = false
    var lastRefresh: Date?

    init(summary: BenchSummary) {
        self.path = summary.path
        self.summary = summary
    }

    var id: String { path }
    var name: String { summary.name }
    var state: BenchState { machine.state }
    var status: BenchStatus? { machine.status }
    var pending: CLIClient.Action? { machine.pending }
    /// No com.benchbar agent yet: `benchbar repair` installs or migrates it.
    var needsService: Bool { !summary.serviceInstalled }
    /// The bench's sites: from the latest status, else from the list.
    var siteRows: [SiteRow] {
        SiteRow.make(sites: status?.sites ?? summary.sites, defaultSite: summary.site,
                     port: status?.ports?.web ?? summary.ports.web)
    }
    /// Procfile.lean runs the scheduler (status --json, CLI 0.4 and later).
    var schedulerOn: Bool? { status?.scheduler }
    /// When the current run started, while it is starting or running.
    var runningSince: Date? {
        guard state == .running || state == .starting else { return nil }
        return status?.startedAt
    }
}

nonisolated enum CLIAvailability: Equatable, Sendable {
    case searching
    case ready(URL)
    case missing(CLIError)
}

/// Every bench and its state, for the menu bar and the popover.
///
/// Sources, fastest first:
///   1. a folder watcher on each bench's logs/.benchbar (the runner writes state.json)
///   2. a poll of `benchbar status --json`: every 30 s, every 5 s while the popover is open
///   3. one HTTP ping after a start, to confirm the site is ready
@Observable
final class BenchStore {
    private(set) var cli: CLIAvailability = .searching
    private(set) var benches: [BenchModel] = []
    private(set) var isLoading = false
    /// Why the bench list could not be loaded, if it could not.
    private(set) var listError: String?

    var selectedPath: String? {
        didSet { if let selectedPath { settings.selectedBench = selectedPath }; notifyChange() }
    }

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored var onAlert: ((BenchModel, BenchAlert) -> Void)?
    /// Called after anything that can change what the menu bar shows.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let makeClient: (URL) -> CLIClient
    @ObservationIgnored private let locator: CLILocator
    @ObservationIgnored private let pinger: @Sendable (String, Int) async -> Int?
    @ObservationIgnored private var client: CLIClient?
    @ObservationIgnored private var watchers: [String: DirectoryWatcher] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var refreshAgain: Set<String> = []
    @ObservationIgnored private var popoverOpen = false
    @ObservationIgnored private var suspended = false

    static let pollInterval: Duration = .seconds(30)
    static let pollTolerance: Duration = .seconds(5)
    static let openPollInterval: Duration = .seconds(5)
    static let openPollTolerance: Duration = .seconds(1)

    init(
        settings: AppSettings,
        locator: CLILocator = CLILocator(),
        makeClient: @escaping (URL) -> CLIClient = { CLIClient(executable: $0) },
        pinger: @escaping @Sendable (String, Int) async -> Int? = { await SitePinger.ping(site: $0, port: $1) }
    ) {
        self.settings = settings
        self.locator = locator
        self.makeClient = makeClient
        self.pinger = pinger
        self.selectedPath = settings.selectedBench.isEmpty ? nil : settings.selectedBench
    }

    // MARK: what the menu bar shows

    var selected: BenchModel? {
        benches.first { $0.path == selectedPath } ?? benches.first
    }

    /// The state to animate: the worst state across all benches (a crash
    /// anywhere stumbles), unknown while the CLI is missing.
    var displayState: BenchState {
        guard case .ready = cli else { return .unknown }
        return BenchAggregate.state(benches.map(\.state))
    }

    /// The bench whose CPU sets the running speed: the selected one while it
    /// is up, else the first bench that is.
    var speedBench: BenchModel? {
        let up: (BenchModel) -> Bool = { $0.state == .running || $0.state == .starting }
        if let selected, up(selected) { return selected }
        return benches.first(where: up)
    }

    // MARK: lifecycle

    /// Finds the CLI, loads the benches, starts watching and polling.
    func start(polling: Bool = true) async {
        locateCLI()
        await reloadBenches()
        if polling { startPolling() }
    }

    func locateCLI() {
        do throws(CLIError) {
            let url = try locator.locate(userPath: settings.cliPath)
            client = makeClient(url)
            cli = .ready(url)
        } catch {
            client = nil
            cli = .missing(error)
            for bench in benches { apply(.cliUnavailable, to: bench) }
        }
        notifyChange()
    }

    /// Called when the user picks a CLI path in Settings or the file picker.
    func useCLI(path: String) async {
        settings.cliPath = path
        locateCLI()
        await reloadBenches()
    }

    /// Runs `benchbar list --json` and keeps existing models (and their state).
    func reloadBenches() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await client.list()
            listError = nil
            var models: [BenchModel] = []
            for summary in list.benches {
                if let existing = benches.first(where: { $0.path == summary.path }) {
                    existing.summary = summary
                    models.append(existing)
                } else {
                    models.append(BenchModel(summary: summary))
                }
            }
            benches = models
            if selectedPath == nil || !models.contains(where: { $0.path == selectedPath }) {
                selectedPath = list.defaultBench ?? models.first?.path
            }
            syncWatchers()
            await refreshAll()
        } catch {
            listError = error.localizedDescription
        }
        notifyChange()
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for bench in benches {
                group.addTask { await self.refresh(bench) }
            }
        }
    }

    /// `benchbar status --json` for one bench. Calls for the same bench never
    /// overlap: a request during a call runs once more when it finishes.
    func refresh(_ bench: BenchModel) async {
        guard let client else { return }
        if inFlight.contains(bench.path) {
            refreshAgain.insert(bench.path)
            return
        }
        inFlight.insert(bench.path)
        defer { inFlight.remove(bench.path) }
        repeat {
            refreshAgain.remove(bench.path)
            do {
                let status = try await client.status(bench: bench.path)
                bench.lastRefresh = Date()
                apply(.observed(status, .status), to: bench)
            } catch {
                bench.lastError = error.localizedDescription
                notifyChange()
            }
        } while refreshAgain.contains(bench.path)
    }

    // MARK: actions

    func perform(_ action: CLIClient.Action, on bench: BenchModel) async {
        guard let client, bench.pending == nil else { return }
        bench.lastError = nil
        apply(.actionStarted(action), to: bench)
        do {
            try await client.perform(action, bench: bench.path)
            apply(.actionFinished(action, succeeded: true), to: bench)
        } catch {
            bench.lastError = error.localizedDescription
            apply(.actionFinished(action, succeeded: false), to: bench)
        }
    }

    /// Turns the scheduler on or off (benchbar service --with-schedule or
    /// --without-schedule), then restarts a running bench so honcho reads
    /// the new Procfile. The caller has asked the user first.
    func setScheduler(_ on: Bool, on bench: BenchModel) async {
        guard let client, bench.pending == nil else { return }
        bench.lastError = nil
        do {
            try await client.setScheduler(on, bench: bench.path)
            await refresh(bench)
            if bench.state == .running || bench.state == .starting {
                await perform(.restart, on: bench)
            }
        } catch {
            bench.lastError = error.localizedDescription
            notifyChange()
        }
    }

    func runDoctor(on bench: BenchModel) async {
        guard let client, !bench.isRunningDoctor else { return }
        bench.isRunningDoctor = true
        bench.doctorError = nil
        defer { bench.isRunningDoctor = false }
        do {
            bench.doctor = try await client.doctor(bench: bench.path)
        } catch {
            bench.doctorError = error.localizedDescription
        }
    }

    // MARK: state file

    /// The runner wrote state.json: apply it at once as a hint, then ask
    /// the CLI for the full truth.
    func stateFileChanged(_ bench: BenchModel) async {
        let url = URL(fileURLWithPath: bench.summary.stateFile)
        if let data = try? Data(contentsOf: url),
           let status = try? BenchJSON.decode(BenchStatus.self, from: data) {
            apply(.observed(status, .stateFile), to: bench)
        }
        await refresh(bench)
    }

    private func syncWatchers() {
        let paths = Set(benches.map(\.path))
        for (path, watcher) in watchers where !paths.contains(path) {
            watcher.stop()
            watchers[path] = nil
        }
        guard !suspended else { return }
        for bench in benches where watchers[bench.path] == nil {
            let folder = URL(fileURLWithPath: bench.summary.stateFile).deletingLastPathComponent()
            let watcher = DirectoryWatcher(target: folder) { [weak self, weak bench] in
                guard let self, let bench else { return }
                Task { await self.stateFileChanged(bench) }
            }
            watcher.start()
            watchers[bench.path] = watcher
        }
    }

    // MARK: polling

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let open = self.popoverOpen
                // tolerance lets macOS batch this wakeup with others, which saves energy
                try? await Task.sleep(
                    for: open ? Self.openPollInterval : Self.pollInterval,
                    tolerance: open ? Self.openPollTolerance : Self.pollTolerance)
                guard !Task.isCancelled else { return }
                await self.refreshAll()
            }
        }
    }

    func setPopoverOpen(_ open: Bool) {
        guard popoverOpen != open else { return }
        popoverOpen = open
        guard !suspended else { return }
        startPolling()
        if open {
            Task { await reloadBenches() }
        }
    }

    /// Sleep, screen lock: stop watching and polling.
    func suspend() {
        suspended = true
        pollTask?.cancel()
        pollTask = nil
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
    }

    /// Wake: catch up at once, then carry on.
    func resume() {
        guard suspended else { return }
        suspended = false
        syncWatchers()
        startPolling()
        Task { await refreshAll() }
    }

    // MARK: effects

    private func apply(_ event: BenchStateMachine.Event, to bench: BenchModel) {
        let effects = bench.machine.handle(event)
        for effect in effects {
            switch effect {
            case .alert(let alert):
                onAlert?(bench, alert)
            case .pingSite:
                Task { await pingAfterStart(bench) }
            case .refresh:
                Task { await refresh(bench) }
            }
        }
        notifyChange()
    }

    private func pingAfterStart(_ bench: BenchModel) async {
        let code = await pinger(bench.summary.site, bench.summary.ports.web)
        if code != nil {
            await refresh(bench)
        }
    }

    private func notifyChange() {
        onChange?()
    }
}
