import Foundation

/// The safety poll, the legacy loop, the chart loop and sleep and wake: when the store looks again.
/// Split from `BenchStore` (MAC-13); same type, same rules.
extension BenchStore {
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
        await forEachLimited(benches) { await self.check($0, finalAsksCLI: true) }
    }

    /// One bench from its files when they can be believed, else the CLI.
    /// `finalAsksCLI`: a stopped, crashed or paused bench asks too.
    func check(_ bench: BenchModel, finalAsksCLI: Bool) async {
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
    func isLegacy(_ bench: BenchModel) -> Bool {
        if failing.contains(bench.path) { return true }
        guard let mode = trust[bench.path], mode.isLegacy else { return false }
        // A bench that never ran under the runner (no state.json) and that
        // the CLI has called stopped, crashed or paused is final: its first
        // start is a new file in a folder that is watched, and the safety
        // poll still asks the CLI. One started by hand (benchfg) leaves no
        // file and only the CLI sees it stop, so it stays in the loop.
        if mode == .legacy(.noFile), BenchTrust.isFinal(bench.state) { return false }
        return true
    }

    /// The legacy loop runs (for the tests).
    var isRunningLegacyLoop: Bool { legacyTask != nil }

    /// Starts the legacy loop when a bench needs it and none runs. Only the
    /// loop ends itself, between two rounds.
    func updateLegacyLoop() {
        guard polling, !suspended, legacyTask == nil, benches.contains(where: isLegacy) else { return }
        let generation = self.generation
        legacyTask = Task(priority: .utility) { [weak self] in
            await self?.runLegacyLoop(generation)
        }
    }

    /// Once a minute, each bench in legacy trust or whose status failed: its
    /// files first (a runner that beats now needs no call), the CLI otherwise. It ends when no bench
    /// needs it, or at its next wake after a suspend.
    func runLegacyLoop(_ generation: Int) async {
        defer { if self.generation == generation { legacyTask = nil } }
        while generation == self.generation {
            await sleeper.sleep(for: Self.legacyInterval, tolerance: Self.legacyTolerance)
            guard generation == self.generation, polling, !suspended else { return }
            let due = benches.filter(isLegacy)
            guard !due.isEmpty else { return }
            Log.poll.info("legacy poll: \(due.count) benches")
            await forEachLimited(due) { await self.check($0, finalAsksCLI: false) }
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
        if open { requestReload() }
    }

    /// BenchBar became the active app (a click back from Terminal or the
    /// browser) with its window open: what the person changed meanwhile, such
    /// as `developer_mode` in a site's config, is not in any watched file, so
    /// the window read stale until the popover was opened. At most every 15 s.
    func appBecameActive() {
        guard windowSight.isOpen, Date().timeIntervalSince(lastReload) > 15 else { return }
        requestReload()
    }

    /// A reload for what came on screen, unless one runs or is queued
    /// already: a click on the menu bar item while the window opens must
    /// not start two rounds of `list` and one `status` per bench.
    func requestReload() {
        guard !suspended, !isLoading, !reloadRequested else { return }
        reloadRequested = true
        Task(priority: .utility) {
            reloadRequested = false
            await reloadBenches()
        }
    }

    /// The BenchBar window opened, closed, came on screen or left it, or
    /// shows another page (MainWindowController).
    func setWindow(_ sight: WindowSight) {
        guard sight != windowSight else { return }
        let wasFast = fastMode
        let opened = sight.isOpen && !windowSight.isOpen
        windowSight = sight
        if opened { windowSession += 1 }
        screenChanged(wasFast: wasFast)
        if opened { requestReload() }
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

    func screenChanged(wasFast: Bool) {
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
    var chartBenches: [BenchModel] {
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
    func updateChartLoop() {
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

    func runChartLoop(_ loop: Int) async {
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

    /// Sleep, screen lock: stop the loops. A loop in a CLI call finishes it;
    /// only its next round is skipped. The folder watchers stay: they cost
    /// nothing without events, and a crash heard while the Mac is locked is
    /// told at once (a CLI call waits for the wake).
    func suspend() {
        guard !suspended else { return }
        suspended = true
        generation += 1
        legacyTask = nil
        updateChartLoop()
        awayBaseline = benches.reduce(into: [:]) { baseline, bench in
            if let status = bench.status, bench.state == .running || bench.state == .starting {
                baseline[bench.path] = status
            }
        }
        toldWhileAway = []
    }

    /// Wake: catch up at once, then carry on. A bench that was running when
    /// the Mac went away and runs again after a failing exit and a new start
    /// crashed meanwhile and was restarted: one notice for it.
    func resume() {
        guard suspended else { return }
        suspended = false
        syncWatchers()
        updateLegacyLoop()
        updateChartLoop()
        let baseline = awayBaseline
        let told = toldWhileAway
        awayBaseline = [:]
        toldWhileAway = []
        Task(priority: .utility) {
            await refreshAll()
            for bench in benches where !told.contains(bench.path) {
                guard let exitCode = CrashWhileAway.exitCode(before: baseline[bench.path], after: bench.status) else { continue }
                Log.poll.info("\(bench.name, privacy: .public): crashed while the Mac was away")
                onAlert?(bench, .crashed(exitCode: exitCode))
            }
        }
    }
}
