import Foundation

/// Start, stop and restart, the one change slot and the scheduler switch.
/// Split from `BenchStore` (MAC-13); same type, same rules.
extension BenchStore {
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
}
