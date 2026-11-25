import Foundation
import Observation

/// One bench as the UI sees it.
@Observable
final class BenchModel: Identifiable {
    let path: String
    var summary: BenchSummary { didSet { refreshSiteRows() } }
    var machine = BenchStateMachine() { didSet { refreshSiteRows() } }
    /// The last failed action or refresh, shown once in the popover.
    var lastError: String?
    /// The action a lease refused (`restart`, `down`): the window offers "Break Lease" for it, as a person's choice.
    var leaseRefusedAction: CLIClient.Action?
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
    @ObservationIgnored var sampler = ResourceSampler()

    init(summary: BenchSummary) {
        self.path = summary.path
        self.summary = summary
        self.siteRows = Self.makeSiteRows(summary: summary, status: nil)
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
    /// The bench's sites: from the latest status, else from the list. Built when the summary or the
    /// status changes, not on every read: a view reads it several times in one `body`, and a view
    /// that reads it is redrawn only when the rows themselves change.
    private(set) var siteRows: [SiteRow]

    private static func makeSiteRows(summary: BenchSummary, status: BenchStatus?) -> [SiteRow] {
        SiteRow.make(sites: status?.sites ?? summary.sites, defaultSite: summary.site,
                     port: status?.ports?.web ?? summary.ports.web)
    }

    private func refreshSiteRows() {
        let rows = Self.makeSiteRows(summary: summary, status: machine.status)
        if rows != siteRows { siteRows = rows }
    }
    /// The CLI has listed this bench's sites (an older one may not).
    var sitesKnown: Bool { (status?.sites ?? summary.sites) != nil }
    /// Procfile.lean runs the scheduler (status --json, CLI 0.4 and later).
    var schedulerOn: Bool? { status?.scheduler }
    /// Updates and adds that stopped part way, from the latest status (CLI 0.8 and later).
    var pendingOperations: [PendingOperation] { (status?.pendingOperations ?? []).filter { !$0.app.isEmpty } }
    /// When the current run started, while it is starting or running.
    var runningSince: Date? {
        guard state == .running || state == .starting else { return nil }
        return status?.startedAt
    }
    /// The uptime's start: only while running. A start or restart shows
    /// "starting" at once, while the status is still the previous run's.
    var upSince: Date? { state == .running ? status?.startedAt : nil }

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
    /// Started without a bench: the CLI listed none, or there is no CLI to
    /// ask. A list that failed is not an answer, the benches may be there.
    var hasNoBench: Bool { benches.isEmpty && listError == nil }
    /// The defaults an update changed (`status --json` notices[], the same for
    /// every bench) until they are dismissed. The window shows them as a banner.
    private(set) var notices: [BenchNotice] = []
    private var changeAnchor: BenchModel?

    var selectedPath: String? {
        didSet { if let selectedPath { settings.selectedBench = selectedPath }; notifyChange() }
    }

    @ObservationIgnored let settings: AppSettings
    /// Pins, recents and sessions of "Open as…" (OpenAsStore), and the
    /// browser tracking that comes with it. Made on first use: nothing exists
    /// for a person who never turns Open as on (`startOpenAsIfOptedIn`).
    @ObservationIgnored var openAsStore: OpenAsStore?
    var openAs: OpenAsStore {
        if let openAsStore { return openAsStore }
        let made = OpenAsStore()
        openAsStore = made
        return made
    }
    /// nil until the feature is first used; for views that only read.
    var openAsIfStarted: OpenAsStore? { openAsStore }
    @ObservationIgnored var onAlert: ((BenchModel, BenchAlert) -> Void)?
    /// Asked before Stop or Restart; false cancels. The app delegate asks only while the bench shares.
    @ObservationIgnored var confirmWhileSharing: ((CLIClient.Action, BenchModel) -> Bool)?
    /// Called after anything that changes what the menu bar shows.
    @ObservationIgnored var onChange: (() -> Void)?
    /// How far each bench's files can be trusted, by path. Logged on change.
    @ObservationIgnored var trust: [String: BenchTrust] = [:]
    /// What of the BenchBar window is on screen (MainWindowController).
    @ObservationIgnored var windowSight = WindowSight()

    @ObservationIgnored let makeClient: (URL) -> CLIClient
    @ObservationIgnored let locator: CLILocator
    @ObservationIgnored let pinger: @Sendable (String, Int) async -> Int?
    @ObservationIgnored let snapshotter: @Sendable (Int32) async -> ProcessTree.Snapshot
    @ObservationIgnored let files: any BenchFiles
    @ObservationIgnored let safetyPoll: any SafetyPolling
    @ObservationIgnored let sleeper: any PollSleeper
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored var client: CLIClient?
    @ObservationIgnored var watchers: [String: DirectoryWatcher] = [:]
    @ObservationIgnored var inFlight: Set<String> = []
    @ObservationIgnored var refreshAgain: Set<String> = []
    /// Benches whose status call is waiting on the CLI right now.
    @ObservationIgnored var asking: Set<String> = []
    /// state.json moved the bench on while its status call ran: that answer
    /// read the bench before, and is dropped for a new one.
    @ObservationIgnored var superseded: Set<String> = []
    /// Benches whose last status call failed: the minute loop asks again
    /// until one works, whatever their files say.
    @ObservationIgnored var failing: Set<String> = []
    /// The state.json claim the CLI denied, by path (`BenchTrust.overruled`).
    @ObservationIgnored var overruled: [String: BenchStatus] = [:]
    @ObservationIgnored var popoverOpen = false
    @ObservationIgnored var polling = false
    @ObservationIgnored var suspended = false
    @ObservationIgnored var lastReload = Date.distantPast
    /// A reload is queued but has not begun: another trigger in that moment
    /// (the popover and the window open together) adds none.
    @ObservationIgnored var reloadRequested = false
    /// What each bench's status said when the Mac went to sleep or locked
    /// (running or starting), to tell a crash that came and went meanwhile.
    @ObservationIgnored var awayBaseline: [String: BenchStatus] = [:]
    /// Benches whose crash was already told while the Mac was locked.
    @ObservationIgnored var toldWhileAway: Set<String> = []
    /// Called when nothing holds the CLI any more (a quit that waits for it).
    @ObservationIgnored var onIdle: (() -> Void)?
    /// Bumped by suspend: a legacy loop from before ends at its next wake.
    /// That loop is never cancelled, since it may be in a CLI call, and a
    /// cancel there makes swift-subprocess SIGTERM bash (a fake "timed out").
    @ObservationIgnored var generation = 0
    @ObservationIgnored var legacyTask: Task<Void, Never>?
    @ObservationIgnored var chartTask: Task<Void, Never>?
    @ObservationIgnored var chartLoop = 0
    /// The bench the runner's speed loop samples every 2 seconds, if any:
    /// the chart loop leaves it alone.
    @ObservationIgnored var speedSampled: String?
    @ObservationIgnored private var lastFacts: MenuFacts?
    @ObservationIgnored let doctorCalls = OnDemandCalls()
    /// Bumped each time the BenchBar window opens: what it shows on demand
    /// (doctor, the app list) is kept for one session.
    var windowSession = 0

    /// A bench whose runner does not beat: `status --json` once a minute.
    static let legacyInterval: Duration = .seconds(60)
    static let legacyTolerance: Duration = .seconds(15)
    /// A running bench on screen that the speed loop does not sample.
    static let chartInterval: Duration = .seconds(5)
    static let chartTolerance: Duration = .seconds(1)
    /// At most this many `status` calls (bash programs) at once: with six
    /// benches one popover click would start eight programs together.
    static let maxParallelStatus = 3

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

    /// The change that holds the CLI, named for a person, nil when none runs.
    /// Quitting asks while this is set (`QuitPolicy`).
    var runningChangeLabel: String? {
        guard let bench = busyBench else { return nil }
        if let activity = bench.activity { return activity }
        if bench.isChangingScheduler { return "Changing the scheduler on \(bench.name)" }
        switch bench.pending {
        case .up?: return "Starting \(bench.name)"
        case .down?: return "Stopping \(bench.name)"
        case .restart?: return "Restarting \(bench.name)"
        case nil: return "A change on \(bench.name)"
        }
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
        defer { isLoading = false; hasLoadedBenches = true; lastReload = Date() }
        do {
            let list = try await client.list()
            if listError != nil { listError = nil }
            // an entry the CLI printed without a path is left out; the others stay
            if !list.skipped.isEmpty { Log.poll.error("list: skipped \(list.skipped.count) entries: \(list.skipped.joined(separator: "; "), privacy: .public)") }
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
            startOpenAsIfOptedIn()
        } catch {
            listError = error.localizedDescription
        }
        notifyChange()
    }

    /// Starts the Open as store once a site has the opt-in on, and drops the
    /// pins of benches and sites that are gone.
    private func startOpenAsIfOptedIn() {
        let optedIn = benches.contains { $0.siteRows.contains { $0.openAsEnabled == true } }
        guard optedIn || openAsStore != nil else { return }
        var known: [String: Set<String>?] = [:]
        for bench in benches {
            known[bench.path] = bench.sitesKnown ? Set(bench.siteRows.map(\.name)) : nil
        }
        openAs.prune(keeping: known)
    }

    /// The banner's Dismiss: gone at once, and `benchbar notices --dismiss ID`
    /// makes it stay gone (a failed call brings it back with the next status).
    func dismissNotice(_ id: String) {
        notices.removeAll { $0.id == id }
        guard let client else { return }
        Task { try? await client.dismissNotice(id) }
    }

    func refreshAll() async {
        await forEachLimited(benches) { await self.refresh($0) }
    }

    /// The benches' calls, `maxParallelStatus` at a time.
    func forEachLimited(_ list: [BenchModel], _ body: @escaping @MainActor (BenchModel) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var next = list.makeIterator()
            for _ in 0..<Self.maxParallelStatus {
                guard let bench = next.next() else { break }
                group.addTask { await body(bench) }
            }
            while await group.next() != nil {
                if let bench = next.next() { group.addTask { await body(bench) } }
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
                // an older CLI has no notices[]: the list stays as it was
                if let list = status.notices, list != notices { notices = list }
                if bench.sitesKnown, let openAs = openAsStore {
                    openAs.forgetSessions(bench: bench.path, keeping: Set(bench.siteRows.filter { $0.openAs == true }.map(\.name)))
                }
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
        return try await client.status(bench: bench.path, deep: bench.state == .running || bench.state == .starting)
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
    /// "busy" when another change holds the slot. `fromLink` is a
    /// `benchbar://` link: it skips the room confirm (see DECISIONS.md).
    @discardableResult
    func perform(_ action: CLIClient.Action, on bench: BenchModel, fromLink: Bool = false, breakLease: Bool = false) async -> String? {
        guard canChange(bench) else { return Self.busyMessage }
        if action != .up, !fromLink, let confirm = confirmWhileSharing, !confirm(action, bench) { return nil }
        return await run(action, on: bench, breakLease: breakLease)
    }

    /// The action itself, for callers that already hold the one change slot
    /// (the restart after a scheduler change).
    @discardableResult
    private func run(_ action: CLIClient.Action, on bench: BenchModel, breakLease: Bool = false) async -> String? {
        guard let base = client else { return Self.noCLIMessage }
        // `breakLease` is only ever true for the click on "Break Lease" after the app's own alert
        let client = breakLease ? base.breakingLease() : base
        bench.lastError = nil
        bench.leaseRefusedAction = nil
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
            if LeaseRefusal.parse(error.localizedDescription) != nil { bench.leaseRefusedAction = action }
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

    // MARK: effects

    func apply(_ event: BenchStateMachine.Event, to bench: BenchModel) {
        // on a copy: writing the machine back tells every view that reads
        // it, so it is written only when the event changed something
        var machine = bench.machine
        let effects = machine.handle(event)
        if machine != bench.machine { bench.machine = machine }
        for effect in effects {
            switch effect {
            case .alert(let alert):
                if suspended, case .crashed = alert { toldWhileAway.insert(bench.path) }
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
    func sampleResources(_ bench: BenchModel) async {
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
        if onIdle != nil, busyBench == nil { onIdle?() }
    }
}
