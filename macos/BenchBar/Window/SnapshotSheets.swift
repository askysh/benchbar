import SwiftUI

/// What a rollback plan says to the person, kept out of the view so a test can read it.
nonisolated enum RollbackText {
    /// The facts under the title of a rollback plan, in the plan's own words.
    static func facts(_ plan: SiteRestorePlan) -> [(label: String, text: String)] {
        var out: [(label: String, text: String)] = []
        out.append((String(localized: "Replaced"), String(localized: "The database and the public and private files of \(plan.site).")))
        let first = plan.rollback?.snapshotFirst ?? "before rollback"
        out.append((String(localized: "Taken first"), String(localized: "A snapshot of \(plan.site) as it is now (label: \(first)). The rollback can be undone from it.")))
        if let rollback = plan.rollback {
            switch rollback.appsMatch {
            case false?:
                let apps = rollback.changedApps.isEmpty ? "" : " (\(rollback.changedApps.joined(separator: ", ")))"
                out.append((String(localized: "Apps"), String(localized: "The bench's apps changed since this snapshot\(apps). Its data goes into the bench's current code.")))
            case true?: out.append((String(localized: "Apps"), String(localized: "The same apps as when the snapshot was taken.")))
            case nil: break
            }
        }
        out.append((String(localized: "Migrate"), plan.migrate ? String(localized: "bench migrate runs after the restore.") : String(localized: "Not run: the site stays on the schema of the snapshot.")))
        out.append((String(localized: "Left alone"), String(localized: "Every other site and /etc/hosts.")))
        return out
    }

    static func needsText(_ needs: [String]) -> String {
        String(localized: "benchbar needs \(needs.joined(separator: ", ")), which it does not have, and BenchBar never asks for or reads it. Run this rollback in Terminal, where benchbar can ask.")
    }
}

/// The snapshots of one site: take one (with a label if you like), roll the site back to one, remove one.
/// Taking a snapshot changes nothing in the site. A rollback and a removal are confirmed first and never the default button.
struct SnapshotsSheet: View {
    let workbench: Workbench
    let bench: BenchModel
    let site: String
    let close: () -> Void
    @State private var label = ""
    @State private var loadError: String?
    @State private var loaded = false
    @State private var rollingBack: SiteSnapshot?
    @State private var removing: SiteSnapshot?
    @Environment(\.pinnedNow) private var pinnedNow

    private var list: SiteSnapshotList? { workbench.snapshots(of: site, on: bench) }
    private var busy: Bool { !workbench.store.canChange(bench) }
    private var labelProblem: String? { SnapshotText.labelProblem(label) }

    private var phase: SheetPhase {
        if let loadError { return .failed(loadError, title: String(localized: "The snapshots could not be read")) }
        if !loaded { return .loading(String(localized: "Reading the snapshots of \(site)…")) }
        if let activity = bench.activity { return .running(activity) }
        return .ready
    }

    var body: some View {
        SheetScaffold(String(localized: "Snapshots of \(site)"),
                      explanation: String(localized: "A snapshot is a backup with files that frappe's pruning never removes, with the apps it was taken with. Taking one changes nothing in the site."),
                      phase: phase, width: .wide) {
            if loaded { content }
        } actions: {
            DoneButton(title: String(localized: "Close"), action: close)
        }
        .task { await load() }
        .sheet(item: $rollingBack) { snapshot in
            SiteRollbackSheet(workbench: workbench, bench: bench, site: site, snapshot: snapshot) { rollingBack = nil }
        }
        .alert("Remove the snapshot \(removing?.title ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Snapshot", role: .destructive) {
                guard let snapshot = removing else { return }
                removing = nil
                Task { await workbench.dropSnapshot(snapshot, of: site, on: bench) }
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Its database dump and files are deleted from sites/\(site)/snapshots. This cannot be undone.")
        }
    }

    @ViewBuilder private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
            TextField("Label (optional)", text: $label, prompt: Text("before the upgrade"))
                .textFieldStyle(.roundedBorder)
            Button("Take Snapshot") { take() }
                .disabled(busy || labelProblem != nil)
        }
        if let labelProblem { SheetNote(labelProblem, tint: .red) }
        if let list, !list.snapshots.isEmpty {
            ForEach(list.snapshots) { snapshot in row(snapshot) }
            SheetNote(summary(list))
        } else {
            SheetOutcome(symbol: "camera", tint: .secondary, title: String(localized: "No snapshots of \(site) yet"),
                         detail: String(localized: "Take one before an upgrade or a risky change; a rollback puts the site back as it was."))
        }
    }

    private func row(_ snapshot: SiteSnapshot) -> some View {
        HStack(alignment: .top, spacing: WindowMetrics.rowSpacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.title).font(.body.weight(.medium))
                Text(SnapshotText.line(snapshot, now: pinnedNow ?? .now)).font(.caption).foregroundStyle(.secondary)
                if let apps = SnapshotText.apps(snapshot) {
                    Text(apps).font(.caption).foregroundStyle(snapshot.appsMatch == false ? .orange : .secondary)
                }
                if snapshot.beforeRollback {
                    Text("The undo point of the last rollback").font(.caption).foregroundStyle(.secondary)
                }
                if !snapshot.complete {
                    Text("Incomplete: a part is missing, so it cannot be rolled back to").font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: WindowMetrics.rowSpacing)
            Button("Roll Back…") { rollingBack = snapshot }
                .disabled(busy || !snapshot.complete)
            Button("Remove…", role: .destructive) { removing = snapshot }
                // the CLI needs --force-undo-point for the undo point, which BenchBar never passes
                .disabled(busy || snapshot.beforeRollback)
                .help(snapshot.beforeRollback ? String(localized: "This is the undo point of the last rollback. Remove it in Terminal if you are sure.") : String(localized: "Delete this snapshot"))
        }
    }

    private func summary(_ list: SiteSnapshotList) -> String {
        let size = ByteCountFormatter.string(fromByteCount: list.totalBytes, countStyle: .file)
        var parts = [String(localized: "The snapshots hold \(size).")]
        if let free = list.freeBytes { parts.append(String(localized: "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) are free on this volume.")) }
        if !list.overLimit.isEmpty { parts.append(String(localized: "\(list.overLimit.count) are beyond the newest \(list.keep); nothing is removed on its own.")) }
        return parts.joined(separator: " ")
    }

    private func load() async {
        loadError = await workbench.loadSnapshots(of: site, on: bench)
        loaded = true
    }

    private func take() {
        let tag = label
        Task {
            if await workbench.takeSnapshot(of: site, label: tag, on: bench) != nil { label = "" }
        }
    }
}

/// Roll Back: the plan from `site rollback --dry-run --json` first, then the person types the site name,
/// then `--apply TOKEN --yes`. The CLI takes a snapshot of the current state first, so the rollback can be undone.
/// The default site is rolled back as a person, and the plan says so. A token the CLI refuses shows Review Again.
struct SiteRollbackSheet: View {
    let workbench: Workbench
    let bench: BenchModel
    let site: String
    let snapshot: SiteSnapshot
    let close: () -> Void
    @State private var flow = PlanReviewFlow<SiteRestorePlan>()
    @State private var typed = ""
    @State private var noMigrate = false
    @Environment(\.pinnedNow) private var pinnedNow

    private var isStale: Bool { if case .stale = flow.stage { true } else { false } }

    private var phase: SheetPhase {
        switch flow.stage {
        case .form:
            if let error = flow.readError { .failed(error, title: String(localized: "No plan to roll \(site) back")) } else { .loading(String(localized: "Reading the snapshot and the bench…")) }
        case .reading: .loading(String(localized: "Reading the snapshot and the bench…"))
        case .reviewing: .ready
        case .applying: .running(String(localized: "Snapshotting and rolling back \(site)…"))
        case .stale: .failed(String(localized: "Nothing was changed. Review the plan again to see what it is now."), title: String(localized: "The bench or the snapshot changed since this plan was shown"))
        }
    }

    var body: some View {
        SheetScaffold(String(localized: "Roll \(site) back"),
                      explanation: String(localized: "Puts \(snapshot.title) back into the site. You see the plan first; nothing runs before you confirm."),
                      phase: phase, width: .wide) {
            if let plan = flow.plan { review(plan) }
        } actions: {
            switch flow.stage {
            case .form, .reading:
                CancelButton(action: close)
                if flow.readError != nil { Button("Review Again") { review() }.keyboardShortcut(.defaultAction) }
            case .reviewing(let plan):
                CancelButton(action: close)
                // destructive: never the default button, and only after the typed name
                Button("Roll Back", role: .destructive) { apply() }
                    .disabled(!plan.canRun || typed != site)
            case .applying:
                EmptyView()
            case .stale:
                CancelButton(action: close)
                Button("Review Again") { review() }.keyboardShortcut(.defaultAction)
            }
        }
        .task { review() }
        .onChange(of: noMigrate) { _, _ in
            flow.edit()
            review()
        }
    }

    @ViewBuilder private func review(_ plan: SiteRestorePlan) -> some View {
        VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing) {
            Text(snapshot.title).font(.headline)
            Text("taken \(SnapshotText.line(snapshot, now: pinnedNow ?? .now)) (\(snapshot.stamp))").font(.caption).foregroundStyle(.secondary)
        }
        if !plan.errors.isEmpty {
            SheetOutcome(symbol: "xmark.octagon.fill", tint: .red, title: String(localized: "This plan cannot run"), detail: plan.errors.joined(separator: "\n"))
        }
        if !plan.needs.isEmpty { SheetNote(RollbackText.needsText(plan.needs), tint: .orange) }
        if SnapshotText.isDefaultSite(plan, benchDefault: bench.status?.site ?? bench.summary.site) { SheetNote(SnapshotText.defaultSiteNote, tint: .orange) }
        ForEach(plan.warnings, id: \.self) { SheetNote($0, tint: .orange) }
        if plan.errors.isEmpty {
            PlanFacts(facts: RollbackText.facts(plan))
            if !plan.steps.isEmpty {
                Text("In order:").font(.callout)
                PlanStepList(rows: plan.steps.map { PlanStepList.Row(name: $0.name, command: nil, note: nil) })
            }
            Toggle("Do not run migrate afterwards", isOn: $noMigrate)
            TextField("Type \(site) to confirm", text: $typed).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            SheetNote(String(localized: "The MariaDB password comes from your Keychain; BenchBar never reads it."))
        }
    }

    private func review() {
        guard flow.review() else { return }
        Task { flow.read(await workbench.rollbackPlan(of: site, to: snapshot.id, noMigrate: noMigrate, on: bench)) }
    }

    private func apply() {
        guard let plan = flow.apply() else { return }
        let noMigrate = noMigrate
        Task {
            let error = await workbench.rollBack(site, to: snapshot.id, noMigrate: noMigrate, token: plan.token, on: bench)
            // a stale token is answered here, with Review Again, not in the banner
            if flow.finish(error: error) { close() } else { workbench.result = nil }
        }
    }
}
