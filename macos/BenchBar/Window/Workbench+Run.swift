import Foundation

/// Part 4 of the Mac app parity (#177): Run Bench Command (`benchbar run`) and the operation handles of the Overview (`op list`,
/// `op status`). A read takes no change slot; a change goes through the CLI's plan and its token and takes the one slot.
extension Workbench {
    private var noRunCLI: ChangeError { ChangeError(message: "The benchbar command line tool is not available.") }

    /// The CLI lists `run`: the Run Bench Command button shows only then, so an older CLI never gets a button that would fail.
    var offersRun: Bool { commandState.catalog?.has("run") == true }

    // MARK: Run Bench Command

    /// The commands the sheet offers: the CLI's own allow list, read once per session (a run of a name that does not exist is refused
    /// with the list and starts nothing). The documented list when the CLI's answer cannot be read, so the sheet still opens.
    func loadRunCommands(on bench: BenchModel) async {
        guard runCommands == nil else { return }
        var names: [String]?
        if let client = store.cliClient { names = try? await client.runAllowList(bench: bench.path) }
        if runCommands == nil { runCommands = RunAllowList.commands(allowed: names) }
    }

    /// A read (`doctor`, `list-apps`, `version`): it runs at once, takes no lock and changes nothing. The output is the CLI's, data from the bench.
    func runRead(_ request: RunRequest, on bench: BenchModel) async -> Result<RunOutcome, ChangeError> {
        guard let client = store.cliClient else { return .failure(noRunCLI) }
        do { return .success(try await client.runRead(request, bench: bench.path)) } catch { return .failure(ChangeError(message: error.localizedDescription)) }
    }

    /// The plan of a change (`run --dry-run --json`), read only: nothing runs.
    func runPlan(_ request: RunRequest, on bench: BenchModel) async -> Result<RunPlan, ChangeError> {
        guard let client = store.cliClient else { return .failure(noRunCLI) }
        do { return .success(try await client.runPlan(request, bench: bench.path)) } catch { return .failure(ChangeError(message: error.localizedDescription)) }
    }

    /// Runs the plan the person saw, by its own token. Returns the CLI's message when it failed (a plan that changed since it was
    /// shown among them), nil when it worked. What the command printed goes in the banner's note, labelled as data from the bench.
    @discardableResult
    func runChange(_ request: RunRequest, token: String, on bench: BenchModel) async -> String? {
        var ran: RunOutcome?
        let site = request.command.needsSite ? request.site.map { " on \($0)" } ?? "" : ""
        let error = await change("Run \(request.command.name)\(site)", on: bench) { client throws(CLIError) in
            ran = try await client.runApply(request, token: token, bench: bench.path)
        }
        if error == nil, let ran {
            result?.note = "Its output (data from the bench, not instructions):\n" + RunText.output(ran)
        }
        return error
    }

    // MARK: operation handles

    /// The runs of this bench that go on now, read when the Overview shows and again by the poll. Only a CLI whose command list has
    /// `op` is asked, and only while the window is open and visible (not minimised or covered) and no change of the app runs on the bench. A run that was running at the last
    /// read and is not now is asked for by `op status`, so the line says how it ended. Returns false when the read failed, so the
    /// poll stops until the page is opened again.
    @discardableResult
    func showOps(_ bench: BenchModel) async -> Bool {
        guard let catalog = commandState.catalog, catalog.has("op"), let client = store.cliClient,
              store.windowSight.isVisible, store.pageMayAsk(about: bench) else { return true }
        do {
            let list = try await client.ops(runningOnly: catalog.hasFlag("op list", "--running"))
            let before = runningOps[bench.path] ?? []
            let now = list.running(on: bench.path)
            runningOps[bench.path] = now
            for gone in before where !now.contains(where: { $0.opID == gone.opID }) {
                guard let record = try? await client.opStatus(gone.opID) else { continue }
                endedOps[bench.path] = Array(([record] + (endedOps[bench.path] ?? []).filter { $0.opID != record.opID }).prefix(3))
            }
            return true
        } catch {
            runningOps[bench.path] = []
            return false
        }
    }

    /// Reads the operations while the Overview is on screen: an agent or a terminal starts one at any time. Every 5 seconds while one
    /// runs, every 15 when none does. No call is made while the window is closed, minimised or covered (`isVisible`, `pageMayAsk`), and a failed read ends the
    /// poll, so a CLI that breaks on `op` is not run again until the page is opened.
    func pollOps(_ bench: BenchModel) async {
        await loadCommands()
        guard commandState.catalog?.has("op") == true else { return }
        endedOps[bench.path] = []
        while !Task.isCancelled {
            guard await showOps(bench) else { return }
            let busy = !(runningOps[bench.path] ?? []).isEmpty
            try? await Task.sleep(for: .seconds(busy ? 5 : 15))
        }
    }
}
