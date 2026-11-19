import SwiftUI

/// What the restore sheet says about a backup and a plan, kept out of the view so a test can read it.
nonisolated enum SiteRestoreText {
    /// "6 hours ago, 5.2 MB, with files": the age as the Sites tab says it.
    static func label(_ backup: SiteBackup, now: Date) -> String {
        let age = backup.time.map { LastBackupLine.age(of: $0, now: now) } ?? backup.stamp
        let size = ByteCountFormatter.string(fromByteCount: backup.sizeBytes, countStyle: .file)
        return "\(age), \(size), \(backup.withFiles ? "with files" : "database only")"
    }

    /// A set the CLI refuses: encrypted (pull decrypts one) or partial.
    static func restorable(_ backup: SiteBackup) -> Bool { !backup.encrypted && !backup.partial }

    /// What an input the CLI would ask for in a terminal means here.
    static func needsText(_ needs: [String]) -> String {
        "benchbar needs \(needs.joined(separator: ", ")), which it does not have, and BenchBar never asks for or reads it. Run this restore in Terminal, where benchbar can ask."
    }
}

/// The plan of a restore: the source, what is backed up first, what it touches, then the steps.
struct SiteRestorePlanView: View {
    let plan: SiteRestorePlan
    @Environment(\.pinnedNow) private var pinnedNow

    private var facts: [(label: String, text: String)] {
        var out: [(label: String, text: String)] = []
        if !plan.touchesText.isEmpty { out.append(("Changes", plan.touchesText.joined(separator: "\n"))) }
        if plan.backupFirst.willRun {
            out.append(("Backed up first", "\(plan.site) is backed up with its files before anything is overwritten. The restore can be undone from that backup."))
        }
        out.append(("Files", plan.source.restoresFiles ? "The public and private files come back with the database." : "Database only: the site's files stay as they are."))
        if plan.source.encryptionKey { out.append(("Encryption key", "The one in the backup is carried over, so stored passwords still decrypt.")) }
        out.append(("Migrate", plan.migrate ? "bench migrate runs after the restore." : "Not run: the site stays on the schema of the backup."))
        out.append(("Left alone", "The default site, /etc/hosts and every other site."))
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
            VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing) {
                Text(plan.new ? "A new site, \(plan.site)" : plan.site).font(.headline)
                if let set = plan.source.set {
                    Text("from the backup made \(SiteRestoreText.label(set, now: pinnedNow ?? .now)) (\(set.stamp))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !plan.errors.isEmpty {
                SheetOutcome(symbol: "xmark.octagon.fill", tint: .red, title: "This plan cannot run", detail: plan.errors.joined(separator: "\n"))
            }
            if !plan.needs.isEmpty {
                SheetNote(SiteRestoreText.needsText(plan.needs), tint: .orange)
            }
            ForEach(plan.warnings, id: \.self) { SheetNote($0, tint: .orange) }
            if plan.errors.isEmpty {
                PlanFacts(facts: facts)
                if !plan.steps.isEmpty {
                    Text("In order:").font(.callout)
                    PlanStepList(rows: plan.steps.map { PlanStepList.Row(name: $0.name, command: nil, note: nil) })
                }
            }
        }
    }
}

/// Pick a backup, Review reads the CLI's plan (`site restore --dry-run --json`), Restore runs it
/// by its token. Restoring into the site itself needs its name typed first and is never the default
/// button; a copy as a new site is not destructive. A token the CLI refuses (the bench or the backup
/// changed since) shows here with Review Again.
struct SiteRestoreSheet: View {
    /// What the sheet starts with: the first backup for a person, filled for a render.
    struct Start {
        var stamp = ""
        var asNew = false
        var copyName = ""
        var typed = ""
        var flow = PlanReviewFlow<SiteRestorePlan>()
    }

    let workbench: Workbench
    let bench: BenchModel
    let site: String
    let close: () -> Void
    @State private var stamp: String
    @State private var asNew: Bool
    @State private var copyName: String
    @State private var typed: String
    @State private var withFiles = true
    @State private var noMigrate = false
    @State private var flow: PlanReviewFlow<SiteRestorePlan>
    @Environment(\.pinnedNow) private var pinnedNow

    init(workbench: Workbench, bench: BenchModel, site: String, start: Start = Start(), close: @escaping () -> Void) {
        self.workbench = workbench
        self.bench = bench
        self.site = site
        self.close = close
        let first = workbench.backups(of: site, on: bench)?.backups.first(where: SiteRestoreText.restorable)?.stamp ?? ""
        _stamp = State(initialValue: start.stamp.isEmpty ? first : start.stamp)
        _asNew = State(initialValue: start.asNew)
        _copyName = State(initialValue: start.copyName)
        _typed = State(initialValue: start.typed)
        _flow = State(initialValue: start.flow)
    }

    private var backups: [SiteBackup] { (workbench.backups(of: site, on: bench)?.backups ?? []).filter(SiteRestoreText.restorable) }
    private var chosen: SiteBackup? { backups.first { $0.stamp == stamp } }
    private var nameValid: Bool { SiteName.isValid(copyName) && !bench.siteRows.contains { $0.name == copyName } }
    private var formValid: Bool { chosen != nil && (asNew ? nameValid : typed == site) }
    private var isStale: Bool { if case .stale = flow.stage { true } else { false } }
    private var target: String { asNew ? copyName : site }

    private var request: SiteRestoreRequest {
        SiteRestoreRequest(target: target, stamp: stamp, fromSite: site, asNew: asNew,
                           withFiles: withFiles && chosen?.withFiles == true, noMigrate: noMigrate)
    }

    private var phase: SheetPhase {
        switch flow.stage {
        case .form:
            if let error = flow.readError { .failed(error, title: "No plan to restore \(target)") } else { .ready }
        case .reading: .loading("Reading the backup and the bench…")
        case .reviewing: .ready
        case .applying: .running(asNew ? "Copying \(site) to \(copyName)…" : "Backing up and restoring \(site)…")
        case .stale: .failed("Nothing was changed. Review the plan again to see what it is now.", title: "The bench or the backup changed since this plan was shown")
        }
    }

    var body: some View {
        SheetScaffold(asNew ? "Copy \(site) to a New Site" : "Restore \(site)",
                      explanation: flow.plan == nil
                          ? "Puts a backup back, into this site or into a copy of it. You see the plan first; nothing runs before you confirm."
                          : "Nothing has run yet. These are the steps; Restore runs exactly this plan.",
                      phase: phase, width: flow.plan == nil ? .regular : .wide) {
            if let plan = flow.plan {
                SiteRestorePlanView(plan: plan)
            } else if flow.stage != .reading, !isStale {
                form
            }
        } leading: {
            if case .reviewing = flow.stage { Button("Back") { flow.edit() } }
        } actions: {
            switch flow.stage {
            case .form, .reading:
                CancelButton(action: close)
                Button("Review") { review() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!formValid || flow.stage == .reading)
            case .reviewing(let plan):
                CancelButton(action: close)
                Button(asNew ? "Make Copy" : "Restore", role: asNew ? nil : .destructive) { apply() }
                    .keyboardShortcut(asNew ? .defaultAction : nil)
                    .disabled(!plan.canRun)
            case .applying:
                EmptyView()
            case .stale:
                CancelButton(action: close)
                Button("Review Again") { review() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private var form: some View {
        if backups.isEmpty {
            SheetOutcome(symbol: "tray", tint: .orange, title: "No backup of \(site) to restore",
                         detail: "Back it up from the site's menu first. Encrypted and partial backups are not restored here.")
        } else {
            Form {
                Picker("Backup", selection: $stamp) {
                    ForEach(backups) { Text(SiteRestoreText.label($0, now: pinnedNow ?? .now)).tag($0.stamp) }
                }
                Picker("Restore into", selection: $asNew) {
                    Text("\(site) itself").tag(false)
                    Text("A new site (a copy)").tag(true)
                }
                if asNew {
                    TextField("New site name", text: $copyName, prompt: Text("\(site)-copy"))
                    if !copyName.isEmpty && !nameValid {
                        Text(SiteName.isValid(copyName) ? "A site with that name exists." : SiteName.rule).font(.caption).foregroundStyle(.red)
                    }
                } else {
                    TextField("Type \(site) to confirm", text: $typed)
                }
                if chosen?.withFiles == true { Toggle("Restore the files too", isOn: $withFiles) }
                Toggle("Do not run migrate afterwards", isOn: $noMigrate)
            }
            .formStyle(.columns)
            SheetNote(asNew
                      ? "The copy is a new site on this bench with the backup's data. \(site) is not touched."
                      : "The data of \(site) is replaced by the backup. \(site) is backed up with its files first, and that backup is listed on the Sites tab afterwards.")
            SheetNote("The MariaDB password comes from your Keychain; BenchBar never reads it.")
        }
    }

    private func review() {
        guard flow.review() else { return }
        Task { flow.read(await workbench.restorePlan(request, on: bench)) }
    }

    private func apply() {
        guard let plan = flow.apply() else { return }
        let request = request
        Task {
            let error = await workbench.restoreSite(request, token: plan.token, on: bench)
            // a stale token is answered here, with Review Again, not in the banner
            if flow.finish(error: error) { close() } else { workbench.result = nil }
        }
    }
}
