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
    var portConflict: PortCheck?
    /// Why the last background status refresh failed; cleared by the next
    /// one that works, so a single slow call does not leave a banner behind.
    var refreshError: String?
    var doctor: DoctorReport?
    var doctorError: String?
    var isRunningDoctor = false
    /// Bumped when an action on the bench ends (start, stop, restart, the
    /// scheduler, a change from the window, a focus pin, a fetch): what the
    /// window shows on demand (doctor, the app list) is asked again
    /// (`BenchStore.stamp(for:)`).
    private(set) var revision = 0
    /// benchbar service is changing the scheduler (and may restart the bench):
    /// every action on this bench waits, the CLI would refuse it anyway (its lock).
    var isChangingScheduler = false
    /// A longer change from the BenchBar window (add an app, a site, an
    /// update, a repair), named for the spinner. Holds the one change slot.
    var activity: String?
    /// CPU and memory of the last ten minutes while the bench runs (`record`).
    /// Views hear of a new sample only while they are on screen.
    var resources: ResourceSampler {
        get { access(keyPath: \.resources); return sampler }
        set { withMutation(keyPath: \.resources) { sampler = newValue } }
    }
    @ObservationIgnored private var sampler = ResourceSampler()

    init(summary: BenchSummary) {
        self.path = summary.path
        self.summary = summary
    }

    var id: String { path }
    var name: String { summary.name }
    var state: BenchState { machine.state }
    var status: BenchStatus? { machine.status }
    var pending: CLIClient.Action? { machine.pending }
    /// A change runs on this bench: start, stop or restart, the scheduler,
    /// or a longer change from the window.
    var isBusy: Bool { pending != nil || isChangingScheduler || activity != nil }
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

    /// One libproc snapshot of the bench's tree: every 2 seconds from the
    /// runner's speed loop for the bench that sets the speed, every 5 for
    /// another bench on screen, and at each status refresh. With `publish`
    /// false the history fills quietly: the popover and the window stay
    /// alive when closed, and would redraw every 2 seconds otherwise.
    func record(_ snapshot: ProcessTree.Snapshot, root: Int32, at time: Date, publish: Bool) {
        if publish {
            resources.record(snapshot, root: root, at: time)
        } else {
            sampler.record(snapshot, root: root, at: time)
        }
    }

    /// Something came on screen: show what was recorded quietly.
    func publishResources() {
        withMutation(keyPath: \.resources) {}
    }

    /// An action on the bench ended.
    func markChanged() { revision += 1 }
}

nonisolated enum CLIAvailability: Equatable, Sendable {
    case searching
    case ready(URL)
    case missing(CLIError)
}

/// What the BenchBar window tells the store: open or not, any of it on
/// screen (open, not minimized, not covered), and the bench whose Overview
/// it shows.
nonisolated struct WindowSight: Equatable, Sendable {
    var isOpen = false
    var isVisible = false
    var overview: String?
}

/// Every bench and its state, for the menu bar and the popover.
///
/// Sources, fastest first:
///   1. a folder watcher on each bench's logs/.benchbar: the runner writes
///      state.json on every transition, and it is the truth while its pid
///      lives and its heartbeat is fresh, or when its state is final
///      (BenchTrust)
///   2. `benchbar status --json`: on launch and wake, after an action, when
///      the popover or the window opens, and when the files cannot say
///   3. a safety poll every 5 minutes, and a 60 second loop only for the
///      benches whose runner does not beat (from before 0.6.1)
///   4. one HTTP ping after a start, to confirm the site is ready
///
/// Nothing runs on a clock for a bench whose runner beats: with the window
/// closed, minutes pass without one process started.
@Observable
final class BenchStore {
    private(set) var cli: CLIAvailability = .searching
    private(set) var benches: [BenchModel] = []
    private(set) var isLoading = false
    /// The bench list has been asked for once (it may have failed): the window
    /// shows its first page, not a spinner.
    private(set) var hasLoadedBenches = false
    /// Why the bench list could not be loaded, if it could not.
    private(set) var listError: String?
    private var changeAnchor: BenchModel?

    var selectedPath: String? {
        didSet { if let selectedPath { settings.selectedBench = selectedPath }; notifyChange() }
    }

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored var onAlert: ((BenchModel, BenchAlert) -> Void)?
    /// Called after anything that changes what the menu bar shows.
    @ObservationIgnored var onChange: (() -> Void)?
    /// How far each bench's files can be trusted, by path. Logged on change.
    @ObservationIgnored private(set) var trust: [String: BenchTrust] = [:]
    /// What of the BenchBar window is on screen (SettingsWindowController).
    @ObservationIgnored private(set) var windowSight = WindowSight()

    @ObservationIgnored private let makeClient: (URL) -> CLIClient
    @ObservationIgnored private let locator: CLILocator
    @ObservationIgnored private let pinger: @Sendable (String, Int) async -> Int?
    @ObservationIgnored private let snapshotter: @Sendable (Int32) async -> ProcessTree.Snapshot
    @ObservationIgnored private let files: any BenchFiles
    @ObservationIgnored private let safetyPoll: any SafetyPolling
    @ObservationIgnored private let sleeper: any PollSleeper
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var client: CLIClient?
    @ObservationIgnored private var watchers: [String: DirectoryWatcher] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var refreshAgain: Set<String> = []
    /// Benches whose status call is waiting on the CLI right now.
    @ObservationIgnored private var asking: Set<String> = []
    /// state.json moved the bench on while its status call ran: that answer
    /// read the bench before, and is dropped for a new one.
    @ObservationIgnored private var superseded: Set<String> = []
    /// Benches whose last status call failed: the minute loop asks again
    /// until one works, whatever their files say.
    @ObservationIgnored private var failing: Set<String> = []
    /// The state.json claim the CLI denied, by path (`BenchTrust.overruled`).
    @ObservationIgnored private var overruled: [String: BenchStatus] = [:]
    @ObservationIgnored private var popoverOpen = false
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var suspended = false
    /// Bumped by suspend: a legacy loop from before ends at its next wake.
    /// That loop is never cancelled, since it may be in a CLI call, and a
    /// cancel there makes swift-subprocess SIGTERM bash (a fake "timed out").
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var legacyTask: Task<Void, Never>?
    @ObservationIgnored private var chartTask: Task<Void, Never>?
    @ObservationIgnored private var chartLoop = 0
    /// The bench the runner's speed loop samples every 2 seconds, if any:
    /// the chart loop leaves it alone.
    @ObservationIgnored private var speedSampled: String?
    @ObservationIgnored private var lastFacts: MenuFacts?
    @ObservationIgnored private let doctorCalls = OnDemandCalls()
    /// Bumped each time the BenchBar window opens: what it shows on demand
    /// (doctor, the app list) is kept for one session.
    private(set) var windowSession = 0

    /// A bench whose runner does not beat: `status --json` once a minute.
    static let legacyInterval: Duration = .seconds(60)
    static let legacyTolerance: Duration = .seconds(15)
    /// A running bench on screen that the speed loop does not sample.
    static let chartInterval: Duration = .seconds(5)
    static let chartTolerance: Duration = .seconds(1)

    init(
        settings: AppSettings,
        locator: CLILocator = CLILocator(),
        makeClient: @escaping (URL) -> CLIClient = { CLIClient(executable: $0) },
        pinger: @escaping @Sendable (String, Int) async -> Int? = { await SitePinger.ping(site: $0, port: $1) },
        snapshotter: @escaping @Sendable (Int32) async -> ProcessTree.Snapshot = { pid in
            await Task.detached(priority: .utility) { ProcessTree.snapshot(root: pid) }.value
        },
        files: any BenchFiles = LiveBenchFiles(),
        safetyPoll: any SafetyPolling = BackgroundSafetyPoll(),
        sleeper: any PollSleeper = TaskSleeper(),
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.locator = locator
        self.makeClient = makeClient
        self.pinger = pinger
        self.snapshotter = snapshotter
        self.files = files
        self.safetyPoll = safetyPoll
        self.sleeper = sleeper
        self.now = now
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

    /// A bench with a change running (start, stop, restart, the scheduler).
    /// The CLI takes one lock for the whole checkout, so while this is set no
    /// other bench may start a change either: it would fail on the lock.
    var busyBench: BenchModel? {
        changeAnchor ?? benches.first(where: \.isBusy)
    }

    /// True when another bench holds the CLI's lock: this one waits.
    func waitsForOtherBench(_ bench: BenchModel) -> Bool {
        guard let busy = busyBench else { return false }
        return busy.path != bench.path
    }

    /// A change may start on the bench now: nothing runs on it and nothing
    /// holds the one change slot. Every action asks this, and every button
    /// that starts one.
    func canChange(_ bench: BenchModel) -> Bool {
        bench.pending == nil && !otherWork(on: bench)
    }

    /// Something other than the bench's own start, stop or restart holds
    /// the slot: the scheduler, a change from the window, another bench.
    private func otherWork(on bench: BenchModel) -> Bool {
        changeAnchor != nil || bench.isChangingScheduler || bench.activity != nil || waitsForOtherBench(bench)
    }

    /// Start, Stop and Restart for one bench, wherever they show: the
    /// popover, the bench page, the sidebar's context menu.
    func controls(for bench: BenchModel) -> BenchControls {
        var cliReady = false
        if case .ready = cli { cliReady = true }
        return .make(state: bench.state, reason: bench.machine.stopReason, pending: bench.pending,
                     needsService: bench.needsService, cliReady: cliReady, otherWork: otherWork(on: bench))
    }

    /// The bench whose CPU sets the running speed: the selected one while it
    /// is up, else the first bench that is.
    var speedBench: BenchModel? {
        let up: (BenchModel) -> Bool = { $0.state == .running || $0.state == .starting }
        if let selected, up(selected) { return selected }
        return benches.first(where: up)
    }

    /// The popover is open or the window is on screen: new resource samples
    /// reach the views at once, and a running bench shown there that the
    /// speed loop does not sample gets the 5 second chart loop. Never a
    /// CLI call on a timer.
    var fastMode: Bool { popoverOpen || windowSight.isVisible }

    // MARK: lifecycle

    /// Finds the CLI, loads the benches, starts watching and the safety poll.
    func start(polling: Bool = true) async {
        locateCLI()
        await reloadBenches()
        if polling { startPolling() }
    }

    func locateCLI() {
        do throws(CLIError) {
            let url = try locator.locate(userPath: settings.cliPath)
            client = makeClient(url)
            if cli != .ready(url) { cli = .ready(url) }
        } catch {
            client = nil
            cli = .missing(error)
            for bench in benches { apply(.cliUnavailable, to: bench) }
        }
        notifyChange()
    }

    /// Called when the user picks a CLI path in Settings or the file picker.
    /// A path inside a Cellar folder is saved as its opt link, which
    /// outlives brew cleanup.
    func useCLI(path: String) async {
        settings.cliPath = path.isEmpty ? path : Homebrew.stablePath(path)
        locateCLI()
        await reloadBenches()
    }

    /// Runs `benchbar list --json` and keeps existing models (and their state).
    func reloadBenches() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false; hasLoadedBenches = true }
        do {
            let list = try await client.list()
            if listError != nil { listError = nil }
            var models: [BenchModel] = []
            for summary in list.benches {
                if let existing = benches.first(where: { $0.path == summary.path }) {
                    if existing.summary != summary { existing.summary = summary }
                    models.append(existing)
                } else {
                    models.append(BenchModel(summary: summary))
                }
            }
            if !models.elementsEqual(benches, by: ===) { benches = models }
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
            superseded.remove(bench.path)
            do {
                let status = try await askStatus(client, bench)
                if bench.refreshError != nil { bench.refreshError = nil }
                if failing.remove(bench.path) != nil {
                    Log.poll.info("\(bench.name, privacy: .public): status answers again")
                }
                // state.json moved the bench on meanwhile: this answer is
                // from before, and the loop asks once more
                if superseded.contains(bench.path) { continue }
                apply(.observed(status, .status), to: bench)
                readFiles(bench, verdict: status)
                await sampleResources(bench)
            } catch {
                let message = error.localizedDescription
                if bench.refreshError != message { bench.refreshError = message }
                await statusFailed(bench)
                notifyChange()
            }
        } while refreshAgain.contains(bench.path)
    }

    /// `status --json`, marked as under way while it waits (`take`).
    private func askStatus(_ client: CLIClient, _ bench: BenchModel) async throws(CLIError) -> BenchStatus {
        asking.insert(bench.path)
        defer { asking.remove(bench.path) }
        return try await client.status(bench: bench.path)
    }

    /// The CLI did not answer (a timeout on a cold start, say). The files
    /// say what they can, and the minute loop asks again until it answers:
    /// with no answer the bench has no mode yet, and no other timer runs.
    private func statusFailed(_ bench: BenchModel) async {
        if failing.insert(bench.path).inserted {
            Log.poll.info("\(bench.name, privacy: .public): status failed, asking every minute")
        }
        let (file, mode) = readFiles(bench)
        if mode == .heartbeat || mode == .terminal, let status = file.status {
            applyFile(status, to: bench)
            await sampleResources(bench)
        }
        updateLegacyLoop()
    }

    // MARK: actions

    static let noCLIMessage = "The benchbar command line tool is not available."
    static let busyMessage = "Another change is still running; try again when it has finished."

    /// Start, stop or restart. Returns the error text, nil on success;
    /// "busy" when another change holds the slot.
    @discardableResult
    func perform(_ action: CLIClient.Action, on bench: BenchModel) async -> String? {
        guard canChange(bench) else { return Self.busyMessage }
        return await run(action, on: bench)
    }

    /// The action itself, for callers that already hold the one change slot
    /// (the restart after a scheduler change).
    @discardableResult
    private func run(_ action: CLIClient.Action, on bench: BenchModel) async -> String? {
        guard let client else { return Self.noCLIMessage }
        bench.lastError = nil
        apply(.actionStarted(action), to: bench)
        defer { bench.markChanged() }
        do {
            if action == .up || action == .restart {
                let check = try await client.portCheck(bench: bench.path)
                let alreadyRunning = action == .up && check.alreadyRunning == true
                bench.portConflict = check.conflicts.isEmpty || alreadyRunning ? nil : check
                if !check.conflicts.isEmpty && !alreadyRunning {
                    throw CLIError.failed(command: "ports", exitCode: 1,
                        message: "Port conflict. Review the proposed resolution before starting.\n" + check.conflicts.joined(separator: "\n"))
                }
            }
            try await client.perform(action, bench: bench.path)
            apply(.actionFinished(action, succeeded: true), to: bench)
            return nil
        } catch {
            bench.lastError = error.localizedDescription
            apply(.actionFinished(action, succeeded: false), to: bench)
            return bench.lastError
        }
    }

    /// The CLI, for the BenchBar window's calls (apps, sites, profiles, repair).
    var cliClient: CLIClient? { client }

    /// Runs one longer change on a bench in the one change slot: nothing
    /// else starts on any bench meanwhile, the bench shows `label`, and the
    /// bench and the list are refreshed afterwards. Returns the error text,
    /// nil on success; "busy" when another change holds the slot.
    func runChange(_ label: String, on bench: BenchModel,
                   _ work: (CLIClient) async throws(CLIError) -> Void) async -> String? {
        guard let client else { return Self.noCLIMessage }
        guard canChange(bench) else { return Self.busyMessage }
        changeAnchor = bench
        bench.activity = label
        notifyChange()
        defer { bench.activity = nil; changeAnchor = nil; bench.markChanged(); notifyChange() }
        do {
            try await work(client)
        } catch {
            await refresh(bench)
            return error.localizedDescription
        }
        await reloadBenches()
        return nil
    }

    /// Turns the scheduler on or off (benchbar service --with-schedule or
    /// --without-schedule), then restarts a running bench so honcho reads
    /// the new Procfile. The caller has asked the user first.
    func setScheduler(_ on: Bool, on bench: BenchModel) async {
        guard let client, canChange(bench) else { return }
        bench.isChangingScheduler = true
        defer { bench.isChangingScheduler = false; bench.markChanged(); notifyChange() }
        bench.lastError = nil
        do {
            try await client.setScheduler(on, bench: bench.path)
            await refresh(bench)
            if bench.state == .running || bench.state == .starting {
                await run(.restart, on: bench)
            }
        } catch {
            bench.lastError = error.localizedDescription
            notifyChange()
        }
    }

    // MARK: on demand

    /// What the window's on demand answers for the bench are kept under:
    /// its pages ask again when this changes (`.task(id:)`).
    func stamp(for bench: BenchModel) -> QueryStamp {
        QueryStamp(session: windowSession, revision: bench.revision)
    }

    /// A page may ask the CLI about the bench on its own: the window is
    /// open (its views live on when it closes, and still update) and no
    /// change runs on the bench (its end changes the stamp, which asks).
    func pageMayAsk(about bench: BenchModel) -> Bool {
        windowSight.isOpen && !bench.isBusy
    }

    /// `doctor --json` now: the Run Doctor buttons, after a repair, a link.
    func runDoctor(on bench: BenchModel) async {
        await askDoctor(bench, force: true)
    }

    /// The Health page is on screen: doctor runs unless the bench has an
    /// answer from this window session and nothing was done to it since.
    func showDoctor(on bench: BenchModel) async {
        guard pageMayAsk(about: bench) else { return }
        await askDoctor(bench, force: false)
    }

    private func askDoctor(_ bench: BenchModel, force: Bool) async {
        guard let client else { return }
        await doctorCalls.ask(bench.path, force: force, stamp: { stamp(for: bench) }) {
            bench.isRunningDoctor = true
            bench.doctorError = nil
            defer { bench.isRunningDoctor = false }
            do {
                bench.doctor = try await client.doctor(bench: bench.path)
            } catch {
                bench.doctorError = error.localizedDescription
            }
        }
    }

    // MARK: state file

    /// The runner wrote to logs/.benchbar (state.json, or its first
    /// heartbeat). The file is the truth when its pid lives with a fresh
    /// heartbeat, or its state is final; otherwise it is a hint until the
    /// CLI answers.
    func stateFileChanged(_ bench: BenchModel) async {
        let (file, mode) = readFiles(bench)
        switch mode {
        case .heartbeat, .terminal:
            await take(file, for: bench)
        case .overruled:
            // the claim the CLI denied, unchanged: no hint, just ask
            await refresh(bench)
        case .legacy:
            if let status = file.status {
                apply(.observed(status.merged(over: bench.status), .stateFile), to: bench)
            }
            await refresh(bench)
        }
    }

    /// state.json as the truth: its core fields over the last full status,
    /// so ports and sites are not blanked. A status call under way read the
    /// bench before this transition, so its answer is dropped for a new one:
    /// it would put the old state back, and nothing would correct it.
    private func take(_ file: BenchFileState, for bench: BenchModel) async {
        guard let status = file.status else { return }
        if applyFile(status, to: bench), asking.contains(bench.path) {
            superseded.insert(bench.path)
            refreshAgain.insert(bench.path)
        }
        await sampleResources(bench)
    }

    /// Applies state.json's status; true when the bench's status moved,
    /// its state or the run (a new runner writes `starting` while the bench
    /// already shows starting from the Start button: a new pid).
    @discardableResult
    private func applyFile(_ status: BenchStatus, to bench: BenchModel) -> Bool {
        // the runner writes running only on a 200 from the site, and stops
        // asking after its ping window; the CLI says running on any answer.
        // A `starting` file for the run the CLI already called running is
        // behind, not news (a site that answers 500, a slow first boot).
        if status.state == .starting, bench.state == .running, let pid = status.pid, pid == bench.status?.pid {
            return false
        }
        let before = (bench.state, bench.status)
        apply(.observed(status.merged(over: bench.status), .stateFile), to: bench)
        return bench.state != before.0 || bench.status != before.1
    }

    /// Reads state.json and the heartbeat's age (no CLI), and notes the
    /// bench's mode: logged when it changes, and the legacy loop follows it.
    /// `verdict`: the CLI's answer just applied. A final state there
    /// overrules a file that claims a run its pid or heartbeat cannot back,
    /// so the minute loop does not ask about a stopped bench for good.
    @discardableResult
    private func readFiles(_ bench: BenchModel, verdict: BenchStatus? = nil) -> (BenchFileState, BenchTrust) {
        reviveWatcher(bench)
        let file = files.read(stateFile: bench.summary.stateFile, now: now())
        var mode = BenchTrust.evaluate(file) { files.isAlive($0) }
        if mode.isLegacy, let claim = file.status, claim.state == .running || claim.state == .starting {
            // while an action runs, the machine drops the CLI's answer as stale
            if let verdict, bench.pending == nil {
                overruled[bench.path] = BenchTrust.isFinal(verdict.state) ? claim : nil
            }
            if overruled[bench.path] == claim { mode = .overruled }
        } else if overruled[bench.path] != nil {
            overruled[bench.path] = nil
        }
        if trust[bench.path] != mode {
            trust[bench.path] = mode
            Log.poll.info("\(bench.name, privacy: .public): \(mode.word, privacy: .public)")
            updateLegacyLoop()
        }
        return (file, mode)
    }

    /// A watcher whose folder a cleanup tool deleted hears nothing more:
    /// start it again when the bench's files are read (the safety poll at
    /// the latest, every minute while the folder is missing).
    private func reviveWatcher(_ bench: BenchModel) {
        guard !suspended, let watcher = watchers[bench.path], watcher.needsRestart else { return }
        watcher.start()
        if !watcher.needsRestart {
            Log.poll.info("\(bench.name, privacy: .public): folder watcher started again")
        }
    }

    /// The bench's folder watcher hears its folder (for the tests).
    func isWatching(_ path: String) -> Bool {
        watchers[path].map { !$0.needsRestart } ?? false
    }

    private func syncWatchers() {
        let paths = Set(benches.map(\.path))
        for (path, watcher) in watchers where !paths.contains(path) {
            watcher.stop()
            watchers[path] = nil
        }
        for path in trust.keys where !paths.contains(path) { trust[path] = nil }
        for path in overruled.keys where !paths.contains(path) { overruled[path] = nil }
        failing.formIntersection(paths)
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

    /// The safety poll, and the legacy loop while a bench needs it. A bench
    /// whose runner beats gets no timer: its folder watcher hears of every
    /// transition, and the heartbeat says the file can be believed.
    func startPolling() {
        guard !polling else { return }
        polling = true
        safetyPoll.start { [weak self] in await self?.safetyCheck() }
        updateLegacyLoop()
    }

    /// The safety poll (every 5 minutes, when macOS sees fit). A bench whose
    /// runner beats is read from its files; every other bench asks the CLI,
    /// the only one to see a bench started by hand (benchfg) or a runner that
    /// stopped beating without a last write.
    func safetyCheck() async {
        guard !suspended else { return }
        Log.poll.info("safety poll: \(self.benches.count) benches")
        await withTaskGroup(of: Void.self) { group in
            for bench in benches {
                group.addTask { await self.check(bench, finalAsksCLI: true) }
            }
        }
    }

    /// One bench from its files when they can be believed, else the CLI.
    /// `finalAsksCLI`: a stopped, crashed or paused bench asks too.
    private func check(_ bench: BenchModel, finalAsksCLI: Bool) async {
        let (file, mode) = readFiles(bench)
        if failing.contains(bench.path) {
            await refresh(bench)
            return
        }
        switch mode {
        case .heartbeat:
            await take(file, for: bench)
        case .terminal where !finalAsksCLI:
            await take(file, for: bench)
        case .overruled where !finalAsksCLI:
            break
        case .terminal, .overruled, .legacy:
            await refresh(bench)
        }
    }

    /// In the minute loop: its files cannot say, or its last status failed.
    private func isLegacy(_ bench: BenchModel) -> Bool {
        trust[bench.path]?.isLegacy == true || failing.contains(bench.path)
    }

    /// The legacy loop runs (for the tests).
    var isRunningLegacyLoop: Bool { legacyTask != nil }

    /// Starts the legacy loop when a bench needs it and none runs. Only the
    /// loop ends itself, between two rounds.
    private func updateLegacyLoop() {
        guard polling, !suspended, legacyTask == nil, benches.contains(where: isLegacy) else { return }
        let generation = self.generation
        legacyTask = Task(priority: .utility) { [weak self] in
            await self?.runLegacyLoop(generation)
        }
    }

    /// Once a minute, each bench in legacy trust or whose status failed: its
    /// files first (a runner that beats now needs no call), the CLI otherwise. It ends when no bench
    /// needs it, or at its next wake after a suspend.
    private func runLegacyLoop(_ generation: Int) async {
        defer { if self.generation == generation { legacyTask = nil } }
        while generation == self.generation {
            await sleeper.sleep(for: Self.legacyInterval, tolerance: Self.legacyTolerance)
            guard generation == self.generation, polling, !suspended else { return }
            let due = benches.filter(isLegacy)
            guard !due.isEmpty else { return }
            Log.poll.info("legacy poll: \(due.count) benches")
            await withTaskGroup(of: Void.self) { group in
                for bench in due {
                    group.addTask { await self.check(bench, finalAsksCLI: false) }
                }
            }
        }
    }

    // MARK: on screen

    /// The popover opened or closed (PopoverController).
    func setPopoverOpen(_ open: Bool) {
        guard popoverOpen != open else { return }
        let wasFast = fastMode
        popoverOpen = open
        screenChanged(wasFast: wasFast)
        // once per opening, every bench, below the work a person waits for
        if open, !suspended { Task(priority: .utility) { await reloadBenches() } }
    }

    /// The BenchBar window opened, closed, came on screen or left it, or
    /// shows another page (SettingsWindowController).
    func setWindow(_ sight: WindowSight) {
        guard sight != windowSight else { return }
        let wasFast = fastMode
        let opened = sight.isOpen && !windowSight.isOpen
        windowSight = sight
        if opened { windowSession += 1 }
        screenChanged(wasFast: wasFast)
        if opened, !suspended { Task(priority: .utility) { await reloadBenches() } }
    }

    /// The runner's speed loop samples this bench now (nil: none). Its
    /// snapshots come in through `record(_:bench:root:)`.
    func setSpeedSampled(_ path: String?) {
        guard speedSampled != path else { return }
        speedSampled = path
        updateChartLoop()
    }

    /// A snapshot from the runner's speed loop: the same libproc read feeds
    /// the bench's resource history.
    func record(_ snapshot: ProcessTree.Snapshot, bench path: String, root: Int32) {
        guard let bench = benches.first(where: { $0.path == path }), bench.status?.pid == root else { return }
        bench.record(snapshot, root: root, at: now(), publish: fastMode)
    }

    private func screenChanged(wasFast: Bool) {
        if fastMode != wasFast {
            Log.poll.info("fast mode \(self.fastMode ? "on" : "off", privacy: .public)")
            // the samples recorded quietly, for the views now on screen
            if fastMode { benches.forEach { $0.publishResources() } }
        }
        updateChartLoop()
    }

    /// The running benches on screen that the speed loop does not sample:
    /// the popover's bench while it is open, and the one whose Overview the
    /// window shows while any of the window is visible.
    private var chartBenches: [BenchModel] {
        guard !suspended else { return [] }
        var shown: Set<String> = []
        if popoverOpen, let selected { shown.insert(selected.path) }
        if windowSight.isVisible, let overview = windowSight.overview { shown.insert(overview) }
        return benches.filter { bench in
            shown.contains(bench.path) && bench.path != speedSampled
                && (bench.state == .running || bench.state == .starting) && (bench.status?.pid ?? 0) > 0
        }
    }

    /// Starts the 5 second chart loop when a bench needs it and stops it when
    /// none does. It only reads libproc, so a cancel stops no CLI call.
    private func updateChartLoop() {
        let due = !chartBenches.isEmpty
        if due, chartTask == nil {
            chartLoop += 1
            let loop = chartLoop
            chartTask = Task(priority: .utility) { [weak self] in
                await self?.runChartLoop(loop)
            }
        } else if !due, let task = chartTask {
            task.cancel()
            chartTask = nil
        }
    }

    private func runChartLoop(_ loop: Int) async {
        defer { if chartLoop == loop { chartTask = nil } }
        while !Task.isCancelled {
            let due = chartBenches
            guard !due.isEmpty else { return }
            for bench in due { await sampleResources(bench) }
            try? await Task.sleep(for: Self.chartInterval, tolerance: Self.chartTolerance)
        }
    }

    /// The chart loop runs (for the tests).
    var isSamplingCharts: Bool { chartTask != nil }

    /// Sleep, screen lock: stop watching and the loops. A loop in a CLI call
    /// finishes it; only its next round is skipped.
    func suspend() {
        suspended = true
        generation += 1
        legacyTask = nil
        updateChartLoop()
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
    }

    /// Wake: catch up at once, then carry on.
    func resume() {
        guard suspended else { return }
        suspended = false
        syncWatchers()
        updateLegacyLoop()
        updateChartLoop()
        Task(priority: .utility) { await refreshAll() }
    }

    // MARK: effects

    private func apply(_ event: BenchStateMachine.Event, to bench: BenchModel) {
        // on a copy: writing the machine back tells every view that reads
        // it, so it is written only when the event changed something
        var machine = bench.machine
        let effects = machine.handle(event)
        if machine != bench.machine { bench.machine = machine }
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

    /// One CPU and memory sample from the bench's process tree, only while
    /// it runs: at each refresh, and from the chart loop.
    private func sampleResources(_ bench: BenchModel) async {
        guard bench.state == .running || bench.state == .starting, let pid = bench.status?.pid, pid > 0 else {
            if bench.resources.isTracking { bench.resources.stop() }
            return
        }
        let snapshot = await snapshotter(pid)
        bench.record(snapshot, root: pid, at: now(), publish: fastMode)
    }

    private func pingAfterStart(_ bench: BenchModel) async {
        let code = await pinger(bench.summary.site, bench.summary.ports.web)
        if code != nil {
            await refresh(bench)
        }
    }

    /// What the menu bar shows and plays: `onChange` runs only when it moves.
    /// Every state (the tooltip counts the benches up) and the speed bench's
    /// pid (a restart moves the speed loop) are in it.
    private struct MenuFacts: Equatable {
        var cli: CLIAvailability
        var states: [BenchState]
        var selected: String?
        var selectedName: String?
        var speedBench: String?
        var speedPid: Int32?
    }

    private func notifyChange() {
        if let onChange {
            let speed = speedBench
            let facts = MenuFacts(cli: cli, states: benches.map(\.state), selected: selectedPath, selectedName: selected?.name,
                                  speedBench: speed?.path, speedPid: speed?.status?.pid)
            if facts != lastFacts {
                lastFacts = facts
                onChange()
            }
        }
        // a bench on screen started or stopped; after the menu bar, which may
        // have handed it to the speed loop
        updateChartLoop()
    }
}
