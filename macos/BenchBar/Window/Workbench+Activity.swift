import Foundation

/// Part 3 of the Mac app parity (#177): snapshots and rollback, the history, leases and the team lockfile.
/// A change goes through the CLI's plan and its token and takes the one change slot; a read takes none.
extension Workbench {
    private var noCLI: ChangeError { ChangeError(message: "The benchbar command line tool is not available.") }

    // MARK: snapshots

    func snapshots(of site: String, on bench: BenchModel) -> SiteSnapshotList? {
        snapshotLists[Self.backupKey(bench.path, site)]
    }

    /// `site snapshots NAME --json`, when the Snapshots sheet opens and after a change to them. Read only; a failure is returned.
    @discardableResult
    func loadSnapshots(of site: String, on bench: BenchModel) async -> String? {
        guard let client = store.cliClient else { return noCLI.message }
        do {
            snapshotLists[Self.backupKey(bench.path, site)] = try await client.snapshots(site: site, bench: bench.path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Takes a snapshot in the change slot; the banner says how it went. Nothing in the site changes.
    @discardableResult
    func takeSnapshot(of site: String, label: String, on bench: BenchModel) async -> SiteSnapshot? {
        var made: SiteSnapshot?
        await change("Take a snapshot of \(site)", on: bench) { client throws(CLIError) in
            made = try await client.takeSnapshot(site: site, label: label, bench: bench.path).snapshot
        }
        await loadSnapshots(of: site, on: bench)
        return made
    }

    /// The plan of a rollback, read only: nothing is snapshotted or restored by reading it.
    func rollbackPlan(of site: String, to snapshot: String, noMigrate: Bool, on bench: BenchModel) async -> Result<SiteRestorePlan, ChangeError> {
        guard let client = store.cliClient else { return .failure(noCLI) }
        do {
            return .success(try await client.rollbackPlan(site: site, snapshot: snapshot, noMigrate: noMigrate, bench: bench.path))
        } catch {
            return .failure(ChangeError(message: error.localizedDescription))
        }
    }

    /// Runs the plan the person saw, by its token. The CLI's message when it failed (a stale token among them), nil when it worked.
    /// The way back (the snapshot of the state before) goes in the banner.
    @discardableResult
    func rollBack(_ site: String, to snapshot: String, noMigrate: Bool, token: String, on bench: BenchModel) async -> String? {
        var ran = RollbackResult()
        let error = await change("Roll back \(site)", on: bench) { client throws(CLIError) in
            ran = try await client.rollback(site: site, snapshot: snapshot, noMigrate: noMigrate, token: token, bench: bench.path)
        }
        if error == nil {
            result?.note = [ran.beforeRollback.map { "The state before is kept as \($0), so this can be undone." }, ran.warnings.joined(separator: " ")]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        await loadSnapshots(of: site, on: bench)
        await loadBackups(bench)
        return error
    }

    /// Removes one snapshot, after the app's own question. The CLI allows it to a person, and never for the undo point of a rollback here.
    @discardableResult
    func dropSnapshot(_ snapshot: SiteSnapshot, of site: String, on bench: BenchModel) async -> String? {
        let error = await change("Remove the snapshot \(snapshot.title) of \(site)", on: bench) { client throws(CLIError) in
            try await client.dropSnapshot(site: site, snapshot: snapshot.id, bench: bench.path)
        }
        await loadSnapshots(of: site, on: bench)
        return error
    }

    // MARK: history and leases

    /// `history --json` for the History pane: every run that changed things on this Mac, newest first.
    func loadHistory(limit: Int = 100) async {
        guard let client = store.cliClient, !loadingHistory else { return }
        loadingHistory = true
        defer { loadingHistory = false }
        do {
            history = try await client.history(bench: nil, limit: limit).history
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }

    /// The leases on this bench, read when its Overview shows and again after a change; a CLI without `lease` shows none.
    func showLeases(_ bench: BenchModel, now: Date = .now) async {
        guard let client = store.cliClient, store.pageMayAsk(about: bench) else { return }
        leases[bench.path] = (try? await client.leases(bench: bench.path).leases.filter { $0.isActive(at: now) }) ?? []
    }

    /// Reads the leases while the Overview is on screen: an agent takes or releases one at any time, and status has no line for them yet.
    func pollLeases(_ bench: BenchModel) async {
        while !Task.isCancelled {
            await showLeases(bench)
            try? await Task.sleep(for: .seconds(15))
        }
    }

    // MARK: the team lockfile

    /// What `lock write` would write, as the CLI's own text. Read only.
    func lockWritePlan(on bench: BenchModel) async -> Result<LockPlan, ChangeError> {
        guard let client = store.cliClient else { return .failure(noCLI) }
        do { return .success(try await client.lockWritePlan(bench: bench.path)) } catch { return .failure(ChangeError(message: error.localizedDescription)) }
    }

    @discardableResult
    func writeLock(on bench: BenchModel) async -> String? {
        let error = await change("Write the lockfile of \(bench.name)", on: bench) { client throws(CLIError) in
            try await client.writeLock(bench: bench.path)
        }
        bench.markChanged()
        await checkLock(bench)
        return error
    }

    /// What `lock apply` would do to the apps, and its token when this CLI gives one. Read only.
    func lockApplyPlan(on bench: BenchModel) async -> Result<LockPlan, ChangeError> {
        guard let client = store.cliClient else { return .failure(noCLI) }
        do { return .success(try await client.lockApplyPlan(bench: bench.path)) } catch { return .failure(ChangeError(message: error.localizedDescription)) }
    }

    /// Runs the apply the person saw: by its token when the plan had one, else `lock apply --yes` after their OK.
    @discardableResult
    func applyLock(token: String?, on bench: BenchModel) async -> String? {
        let error = await change("Apply the lockfile to \(bench.name)", on: bench) { client throws(CLIError) in
            try await client.applyLock(token: token, bench: bench.path)
        }
        await loadApps(bench, liveSites: true)
        await checkLock(bench)
        return error
    }
}

/// When "Start Services Only" and "Stop Services" are offered: the bench is not running. A bench with no service
/// installed has no "stopped" state to read (its state is the CLI's `not_adopted`), so its processes decide.
/// `up --services-only` needs no installed service (the CLI says so), and `down` stops the Redis it started.
nonisolated enum ServicesOnly {
    static func notRunning(needsService: Bool, state: BenchState, processesRunning: Bool?) -> Bool {
        needsService ? processesRunning != true : state == .stopped
    }
}
