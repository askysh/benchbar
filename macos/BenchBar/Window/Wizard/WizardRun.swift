import Foundation
import Observation

/// The I/O half of the first run wizard: runs the CLI for the effects
/// `WizardState` asks for and feeds the answers back as events. Like
/// RepairRun and PortSetupRun, so the rules are tested without views.
///
/// The install holds the store's one change slot (`runChange`) for as long as
/// it runs, with a stand in for the bench that does not exist yet, as
/// PortSetupRun does before a bench is in the store: every bench's buttons
/// wait, because the CLI holds a checkout wide lock.
@Observable
final class WizardRun {
    private(set) var state: WizardState
    /// The tail of the run log, for the Command output disclosure.
    private(set) var logLines: [String] = []
    /// Why `xcode-select --install` did not open Apple's dialog.
    private(set) var commandLineToolsMessage: String?
    private(set) var openedCommandLineTools = false

    let store: BenchStore
    /// Find Benches and its folder scan.
    @ObservationIgnored var openFindBenches: () -> Void = {}
    /// Esc on the first page.
    @ObservationIgnored var leave: () -> Void = {}
    /// The wizard is over; the path is the new bench, when there is one.
    /// Done page: Take the Tour.
    @ObservationIgnored var tour: () -> Void = {}
    @ObservationIgnored var finished: (String?) -> Void = { _ in }
    @ObservationIgnored var openURL: (String) -> Void = { Workspace.open($0) }
    /// `xcode-select --install`, the one command that is not benchbar.
    @ObservationIgnored var installCommandLineTools: () async -> String? = { await CommandLineTools.install() }
    @ObservationIgnored var pollInterval: Duration = .seconds(4)
    /// Polling waits while the window cannot be seen (nil: ask the store).
    @ObservationIgnored var windowIsVisible: (() -> Bool)?

    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// Stop was pressed before the install process started: it must not start.
    @ObservationIgnored private var stopBeforeStart = false
    @ObservationIgnored private var installTask: Task<Result<Int32, CLIError>, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var tailer: LogTailer?
    @ObservationIgnored private var checkGeneration = 0
    @ObservationIgnored private var planGeneration = 0
    @ObservationIgnored private var pollGeneration = 0

    static let logLineLimit = 300
    static let logLineLength = 400

    init(store: BenchStore, state: WizardState = WizardState()) {
        self.store = store
        self.state = state
    }

    var isInstalling: Bool { state.isInstalling }

    /// The store is free for the install to take the change slot.
    var canStartChange: Bool { store.busyBench == nil }

    func send(_ event: WizardState.Event) {
        let effects = state.send(event)
        for effect in effects { perform(effect) }
        syncPolling()
    }

    /// Return and Esc, and the buttons: the same events.
    func primary() { send(.primary) }
    func back() { send(.back) }

    /// Starts over when a finished wizard is opened again from "+" > New Bench…;
    /// a wizard in the middle of something stays where it is.
    func reopen() {
        guard !state.isInstalling else { return }
        if state.page == .done || state.page == .cliOnly {
            stopTailing()
            state = WizardState()
            logLines = []
        }
    }

    /// Puts the state on a page without running anything (the snapshots).
    func preview(_ events: [WizardState.Event]) {
        for event in events { _ = state.send(event) }
    }

    func setLogLines(_ lines: [String]) { logLines = lines }

    // MARK: effects

    private func perform(_ effect: WizardState.Effect) {
        switch effect {
        case .checkPrerequisites(let folder): check(folder: folder)
        case .loadProfiles: loadProfiles()
        case .planInstall(let request): plan(request)
        case .startInstall(let request, let withRoot): startInstall(request, withRootPassword: withRoot)
        case .stopInstall:
            stopBeforeStart = true
            installTask?.cancel()
        case .openFindBenches: openFindBenches()
        case .openSite(let url): openURL(url)
        case .leave: leave()
        case .finished:
            stopTailing()
            finished(state.progress.done?.bench ?? state.progress.plan?.bench)
        }
    }

    private func check(folder: String) {
        guard let client = store.cliClient else {
            send(.prerequisitesFailed(BenchStore.noCLIMessage))
            return
        }
        checkGeneration += 1
        let generation = checkGeneration
        Task { @MainActor in
            let event: WizardState.Event
            do {
                event = .prerequisites(try await client.prerequisites(bench: folder))
            } catch {
                event = .prerequisitesFailed(error.localizedDescription)
            }
            // a later check (another folder) has the say
            guard generation == checkGeneration else { return }
            send(event)
        }
    }

    private func loadProfiles() {
        guard let client = store.cliClient else { send(.profilesFailed(BenchStore.noCLIMessage)); return }
        Task { @MainActor in
            do {
                send(.profiles(try await client.profiles()))
            } catch {
                send(.profilesFailed(error.localizedDescription))
            }
        }
    }

    private func plan(_ request: InstallRequest) {
        guard let client = store.cliClient else { send(.planFailed(BenchStore.noCLIMessage)); return }
        planGeneration += 1
        let generation = planGeneration
        let password = state.form.adminPassword.value
        Task { @MainActor in
            let event: WizardState.Event
            do {
                event = .planned(try await client.installPlan(request, adminPassword: password))
            } catch {
                event = .planFailed(error.localizedDescription)
            }
            guard generation == planGeneration else { return }
            send(event)
        }
    }

    // MARK: the install

    /// The Review page's Install was the confirmation: `--yes` goes with it.
    private func startInstall(_ request: InstallRequest, withRootPassword: Bool) {
        guard store.cliClient != nil else {
            send(.installEnded(exitCode: 1, error: BenchStore.noCLIMessage))
            return
        }
        let admin = state.form.adminPassword.value
        let root = withRootPassword ? state.rootPassword.value : nil
        stopTailing()
        logLines = []
        stopBeforeStart = false
        let anchor = BenchModel(summary: Self.placeholder(request))
        runTask = Task { @MainActor in
            let (events, continuation) = AsyncStream<InstallEvent>.makeStream()
            let consumer = Task { @MainActor in
                for await event in events {
                    self.send(.install(event))
                    if case .plan(let plan) = event { self.tail(plan.log) }
                }
            }
            var code: Int32 = 1
            var failure: String?
            // the install runs in a task of its own: Stop cancels that one, and
            // the change slot is still released and the bench list read after it
            let busy = await store.runChange("Installing \(request.site)", on: anchor) { client throws(CLIError) in
                // a Stop that came before this point: no process at all
                if self.stopBeforeStart { return }
                let work = Task { () async -> Result<Int32, CLIError> in
                    do throws(CLIError) {
                        return .success(try await client.install(request, adminPassword: admin, rootPassword: root) { event in
                            continuation.yield(event)
                        })
                    } catch {
                        return .failure(error)
                    }
                }
                self.installTask = work
                switch await work.value {
                case .success(let value): code = value
                case .failure(let error): failure = error.localizedDescription
                }
            }
            continuation.finish()
            await consumer.value
            installTask = nil
            tailer?.readNew()
            send(.installEnded(exitCode: code, error: failure ?? busy))
            stopTailing()
        }
    }

    /// The anchor of the change slot: a bench that is not there yet.
    static func placeholder(_ request: InstallRequest) -> BenchSummary {
        BenchSummary(path: request.benchDir, name: URL(fileURLWithPath: request.benchDir).lastPathComponent,
                     site: request.site, label: "", webURL: "",
                     ports: BenchPorts(web: 8000, socketio: 9000, redisQueue: 11000, redisCache: 13000),
                     isDefault: false, serviceInstalled: false, stateFile: "")
    }

    // MARK: the run log

    /// Follows the run log the plan names, bounded: the last 300 lines of at most 400 characters.
    private func tail(_ path: String?) {
        guard let path, !path.isEmpty, tailer == nil else { return }
        let tailer = LogTailer(url: URL(fileURLWithPath: path), initialBytes: 64 * 1024, onLines: { [weak self] text in
            self?.append(text)
        }, onReset: { [weak self] in self?.logLines = [] })
        self.tailer = tailer
        tailer.start()
    }

    func append(_ text: String) {
        var lines = logLines
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lines.append(raw.count > Self.logLineLength ? String(raw.prefix(Self.logLineLength)) + "…" : String(raw))
        }
        if lines.count > Self.logLineLimit { lines.removeFirst(lines.count - Self.logLineLimit) }
        logLines = lines
    }

    private func stopTailing() {
        tailer?.stop()
        tailer = nil
    }

    // MARK: Command Line Tools and the polling

    /// `xcode-select --install`: opens Apple's dialog; the row notices when it is done.
    func startCommandLineTools() async {
        commandLineToolsMessage = nil
        commandLineToolsMessage = await installCommandLineTools()
        openedCommandLineTools = commandLineToolsMessage == nil
        syncPolling()
    }

    /// Polls the prerequisites every few seconds, only while the Check Your
    /// Mac page is up and Command Line Tools are missing, and only while the
    /// window can be seen. Stops as soon as either stops being true.
    private func syncPolling() {
        guard state.shouldPoll else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: interval, tolerance: .seconds(1))
                guard let self, !Task.isCancelled, state.shouldPoll else { break }
                if windowIsVisible?() ?? store.windowSight.isVisible { await refreshQuietly() }
            }
            // a newer loop owns the handle by now
            if let self, pollGeneration == generation { pollTask = nil }
        }
    }

    var isPolling: Bool { pollTask != nil }

    /// The poll's check: no spinner, and the answer of a page that is gone is dropped.
    private func refreshQuietly() async {
        guard let client = store.cliClient else { return }
        let folder = state.resolvedFolder
        guard let report = try? await client.prerequisites(bench: folder), state.page == .check else { return }
        send(.prerequisites(report))
    }
}
