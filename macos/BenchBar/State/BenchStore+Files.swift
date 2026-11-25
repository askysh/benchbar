import Foundation

/// What a bench's own files say (`logs/.benchbar`, the heartbeat) and the folder watchers that hear them.
/// Split from `BenchStore` (MAC-13); same type, same rules.
extension BenchStore {
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
            // the claim the CLI denied, unchanged: no hint, just ask (not
            // while locked: the wake asks every bench once)
            if !suspended { await refresh(bench) }
        case .legacy:
            if let status = file.status {
                apply(.observed(status.merged(over: bench.status), .stateFile), to: bench)
            }
            if !suspended { await refresh(bench) }
        }
    }

    /// state.json as the truth: its core fields over the last full status,
    /// so ports and sites are not blanked. A status call under way read the
    /// bench before this transition, so its answer is dropped for a new one:
    /// it would put the old state back, and nothing would correct it.
    func take(_ file: BenchFileState, for bench: BenchModel) async {
        guard let status = file.status else { return }
        if applyFile(status, to: bench), asking.contains(bench.path) {
            superseded.insert(bench.path)
            refreshAgain.insert(bench.path)
        }
        if !suspended { await sampleResources(bench) }
    }

    /// Applies state.json's status; true when the bench's status moved,
    /// its state or the run (a new runner writes `starting` while the bench
    /// already shows starting from the Start button: a new pid).
    @discardableResult
    func applyFile(_ status: BenchStatus, to bench: BenchModel) -> Bool {
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
    func readFiles(_ bench: BenchModel, verdict: BenchStatus? = nil) -> (BenchFileState, BenchTrust) {
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
    func reviveWatcher(_ bench: BenchModel) {
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

    func syncWatchers() {
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
}
