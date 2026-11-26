import SwiftUI

/// The apps of one bench: what is cloned, on which branch, on which sites,
/// and the three changes the CLI offers (add, install on a site, update).
struct BenchApps: View {
    let store: BenchStore
    let workbench: Workbench
    let bench: BenchModel
    @State private var adding = false
    @State private var updating: AppInfo?
    @State private var resumingUpdate: PendingOperation?
    @State private var resumingAdd: PendingOperation?
    @State private var discarding: PendingOperation?

    private var busy: Bool { !store.canChange(bench) }
    private var siteNames: [String] { bench.siteRows.map(\.name) }

    var body: some View {
        let list = workbench.apps[bench.path]
        Form {
            if !bench.pendingOperations.isEmpty {
                PendingOperationsSection(operations: bench.pendingOperations, busy: busy) { operation in
                    if operation.isUpdate { resumingUpdate = operation } else { resumingAdd = operation }
                } discard: { discarding = $0 }
            }
            Section {
                if let list {
                    ForEach(list.apps) { app in row(app, sitesKnown: list.sitesKnown) }
                    if list.apps.isEmpty { Text("No apps").foregroundStyle(.secondary) }
                    if list.apps.filter({ $0.name != "frappe" }).isEmpty {
                        EmptyStateBlock(symbol: "square.stack.3d.up", title: "Only Frappe so far",
                                        line: "Add ERPNext or any app from the registry or a git repository.",
                                        actions: [("Add App…", { adding = true })], disabled: busy)
                    }
                } else if workbench.loadingApps.contains(bench.path) {
                    HStack { ProgressView().controlSize(.small); Text("Reading apps…").foregroundStyle(.secondary) }
                }
                if let error = workbench.appsError[bench.path] {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let siteError = list?.sitesError {
                    Text("Site lists are from the last successful read: \(siteError)")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                HStack(spacing: WindowMetrics.rowSpacing) {
                    Text("Apps")
                    Spacer()
                    MoreMenu(help: String(localized: "Refresh the site lists or check the remotes")) {
                        Button { Task { await workbench.loadApps(bench, liveSites: true) } } label: {
                            Label("Refresh Site Lists", systemImage: "arrow.clockwise")
                        }
                        .disabled(workbench.loadingApps.contains(bench.path))
                        .help("Ask bench which sites have which app (needs MariaDB)")
                        Button { Task { await workbench.checkRemotes(bench) } } label: {
                            Label("Check Remotes", systemImage: "arrow.down.circle")
                        }
                        .disabled(workbench.checkingRemotes.contains(bench.path))
                        .help("git fetch the apps your focus apps need, to see how far behind they are (only .git changes)")
                    }
                    Button { adding = true } label: { Label("Add App…", systemImage: "plus") }
                        .primaryAction()
                        .disabled(busy)
                }
            } footer: {
                Text("Apps come from the app registry or any git repository, including private GitHub repos your SSH key can read. BenchBar never runs bench update.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // kept for the window session, like Health's doctor report
        .task(id: store.stamp(for: bench)) { await workbench.showApps(bench) }
        .sheet(isPresented: $adding) {
            AddAppSheet(workbench: workbench, bench: bench, sites: siteNames) { adding = false }
        }
        .sheet(item: $updating) { app in
            UpdateAppSheet(workbench: workbench, bench: bench, app: app.name) { updating = nil }
        }
        .sheet(item: $resumingUpdate) { operation in
            UpdateAppSheet(workbench: workbench, bench: bench, app: operation.app) { resumingUpdate = nil }
        }
        .sheet(item: $resumingAdd) { operation in
            AddAppSheet(workbench: workbench, bench: bench, sites: siteNames, start: .init(entries: [AppAddEntry(source: operation.app)])) { resumingAdd = nil }
        }
        .alert("Drop the record of \(discarding?.app ?? "")?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
            Button("Drop the Record", role: .destructive) {
                guard let operation = discarding else { return }
                discarding = nil
                Task { await workbench.discardPending(operation, on: bench) }
            }
            Button("Cancel", role: .cancel) { discarding = nil }
        } message: {
            Text(discarding.map(PendingText.discardMessage) ?? "")
        }
    }

    /// `sitesKnown` false: bench was never asked which sites have the app,
    /// so the row says nothing about sites rather than "on no site".
    private func row(_ app: AppInfo, sitesKnown: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name).font(.body.weight(.medium))
                    if let version = app.version { Text(version).font(.caption).foregroundStyle(.secondary) }
                    if app.dirty { Tag(text: "local changes", color: .orange) }
                    if !app.inAppsTxt { Tag(text: "not in apps.txt", color: .red) }
                    if let branch = app.branch, let policy = app.policyBranch, branch != policy {
                        Tag(text: "expected \(policy)", color: .orange)
                    }
                    if app.isFocus { Tag(text: "focus", color: .accentColor) }
                    if app.pin == .ignore { Tag(text: "ignored", color: .secondary) }
                    if app.isStaleDependency { Tag(text: "behind", color: .orange) }
                }
                if let words = app.focusSummary ?? app.dependencySummary {
                    Text(words).font(.caption).foregroundStyle(app.isStaleDependency ? .orange : .secondary)
                }
                Text([app.branch.map { "branch \($0)" } ?? "detached", app.repo].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if sitesKnown {
                    Text(app.sites.isEmpty ? "on no site yet" : "on \(app.sites.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Update…") { updating = app }
                .disabled(busy || app.branch == nil || app.dirty)
                .help(app.dirty ? "The app has local changes; commit or stash them first" : "Shows the changelog before anything changes")
            AppMenu(app: app, missingSites: app.name == "frappe" || !sitesKnown ? [] : AppSource.sitesWithout(app, among: siteNames), busy: busy) { site in
                Task { await workbench.installApp(app.name, site: site, on: bench) }
            } setFocus: { pin in
                Task { await workbench.setFocus(pin, app: app.name, on: bench) }
            }
        }
        .padding(.vertical, 2)
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Fill in one app or several, Review reads the CLI's plan (`app add --dry-run --json`: one plan, one token),
/// Add App runs it by its token. A token the CLI refuses (the bench changed since) shows here, with Review
/// Again; any other failure closes the sheet and the change banner has it.
struct AddAppSheet: View {
    /// What the sheet starts with: one empty app for a person, filled for a render.
    struct Start {
        var entries = [AppAddEntry()]
        var flow = PlanReviewFlow<AppAddPlan>()
    }

    let workbench: Workbench
    let bench: BenchModel
    let sites: [String]
    let close: () -> Void
    @State private var entries: [AppAddEntry]
    @State private var flow: PlanReviewFlow<AppAddPlan>

    init(workbench: Workbench, bench: BenchModel, sites: [String], start: Start = Start(), close: @escaping () -> Void) {
        self.workbench = workbench
        self.bench = bench
        self.sites = sites
        self.close = close
        _entries = State(initialValue: start.entries)
        _flow = State(initialValue: start.flow)
    }

    private var several: Bool { entries.count > 1 }
    private var names: [String] { flow.plan?.appNames ?? entries.filter { !$0.isEmpty }.map(\.displayName) }
    private var title: String { AppAddBatch.title(names) }
    private var problem: String? { AppAddBatch.problem(entries) }

    private var phase: SheetPhase {
        switch flow.stage {
        case .form:
            if let error = flow.readError { .failed(error, title: String(localized: "No plan for \(title)")) } else { .ready }
        case .reading: .loading(several ? String(localized: "Reading the repositories and the bench…") : String(localized: "Reading the repository and the bench…"))
        case .reviewing: .ready
        case .applying: .running(String(localized: "Adding \(title)…"))
        case .stale: .failed(String(localized: "Nothing was changed. Review the plan again to see what it is now."), title: String(localized: "The bench changed since this plan was shown"))
        }
    }

    var body: some View {
        SheetScaffold(several || flow.plan?.isBatch == true ? String(localized: "Add Apps to \(bench.name)") : String(localized: "Add an App to \(bench.name)"),
                      explanation: flow.plan == nil
                          ? String(localized: "Clones apps from the app registry or git repositories and installs them. You see the plan first.") : String(localized: "Nothing has run yet. These are the steps; \(runTitle) runs exactly this plan."),
                      phase: phase, width: flow.plan == nil ? .regular : .wide) {
            if let plan = flow.plan {
                AppAddPlanView(plan: plan)
            } else if flow.stage != .reading, !isStale {
                form
            }
        } leading: {
            if case .reviewing = flow.stage {
                Button("Back") { flow.edit() }
            }
        } actions: {
            switch flow.stage {
            case .form, .reading:
                CancelButton(action: close)
                Button("Review") { review() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || flow.stage == .reading)
            case .reviewing(let plan):
                CancelButton(action: close)
                Button(runTitle) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!plan.canRun)
            case .applying:
                EmptyView()
            case .stale:
                CancelButton(action: close)
                Button("Review Again") { review() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var runTitle: String { flow.plan?.isBatch == true ? "Add \(flow.plan?.apps?.count ?? 0) Apps" : "Add App" }
    private var isStale: Bool { if case .stale = flow.stage { true } else { false } }

    @ViewBuilder private var form: some View {
        ForEach($entries) { $entry in
            VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing) {
                if several {
                    HStack {
                        Text("App \((entries.firstIndex { $0.id == entry.id } ?? 0) + 1)").font(.callout.weight(.medium))
                        Spacer()
                        Button("Remove") { entries.removeAll { $0.id == entry.id } }.buttonStyle(.link).controlSize(.small)
                    }
                }
                Form {
                    // verbatim: a string literal Text reads markdown and turns the URL into a link
                    TextField("App or repository", text: $entry.source, prompt: Text(verbatim: "erpnext or https://github.com/org/app"))
                    TextField("Branch", text: $entry.branch, prompt: Text(AppSource.isURL(entry.source) ? "the repository's default" : "the profile's branch"))
                    TextField("Commit", text: $entry.commit, prompt: Text("optional: pin to a commit, 7 to 40 hex characters"))
                    Picker("Install on", selection: $entry.site) {
                        Text("No site yet").tag("")
                        ForEach(sites, id: \.self) { Text($0).tag($0) }
                    }
                }
                .formStyle(.columns)
            }
        }
        Button { entries.append(AppAddEntry()) } label: { Label("Add Another App", systemImage: "plus") }
            .disabled(entries.count >= AppAddBatch.maxApps)
            .help("Several apps are one plan with one token; an app another one needs is cloned once")
        if let problem, entries.contains(where: { !$0.isEmpty }) { SheetNote(problem, tint: .orange) }
        SheetNote(entries.contains { AppSource.isURL($0.source) }
                  ? String(localized: "Private repositories work when your SSH key (or a git credential helper) can read them; BenchBar checks access first, so a missing key fails in seconds.") : String(localized: "A name from the app registry gets the branch that matches this bench's profile."))
        SheetNote(String(localized: "Review reads the repositories and shows the steps. Adding runs bench get-app, installs each app's requirements and builds the assets, which can take several minutes; the bench keeps running."))
    }

    private func review() {
        guard flow.review() else { return }
        let entries = entries.filter { !$0.isEmpty }
        Task { flow.read(await workbench.addAppPlan(entries, on: bench)) }
    }

    private func apply() {
        guard let plan = flow.apply() else { return }
        let entries = entries.filter { !$0.isEmpty }
        Task {
            let error = await workbench.addApp(entries, token: plan.token, on: bench)
            // a stale token is answered here, with Review Again, not in the banner
            if flow.finish(error: error) { close() } else { workbench.result = nil }
        }
    }
}

/// The changelog first (app update --dry-run --json), then the update.
struct UpdateAppSheet: View {
    let workbench: Workbench
    let bench: BenchModel
    let app: String
    let close: () -> Void
    @State private var plan: AppUpdatePlan?
    @State private var error: String?

    private var phase: SheetPhase {
        if let error { return .failed(error, title: String(localized: "No changelog for \(app)")) }
        guard let plan else { return .loading(String(localized: "Fetching the changes…")) }
        return plan.isUpToDate ? .done(.success(plan.branch.map { String(localized: "\(app) is up to date on \($0).") }
                                              ?? String(localized: "\(app) is up to date on its branch."))) : .ready
    }

    var body: some View {
        SheetScaffold(plan?.pending == nil ? String(localized: "Update \(app)") : String(localized: "Finish the Update of \(app)"),
                      explanation: plan?.pending == nil
                          ? String(localized: "Shows the new commits and the steps before anything changes.") : String(localized: "An earlier update stopped part way. Only the steps that are left run."),
                      phase: phase) {
            if let pending = plan?.pending {
                SheetOutcome(symbol: "exclamationmark.triangle.fill", tint: .orange, title: pending.title, detail: pending.detail)
            }
            if let plan, !plan.isUpToDate {
                Text(Wording.newCommits(plan.commitsTotal, on: plan.branch ?? "the branch"))
                    .font(.callout)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.commits) { commit in
                        HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
                            Text(commit.sha).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(commit.subject).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(WindowMetrics.bannerPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius))
                Text("Then, in order:").font(.callout)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(plan.steps) { step in
                        Label(step.name, systemImage: "circle").font(.callout)
                    }
                }
                if !plan.sites.isEmpty && plan.pending == nil {
                    SheetNote(String(localized: "Each site is backed up before it is migrated: \(plan.sites.joined(separator: ", "))."))
                }
            }
        } actions: {
            if let plan, !plan.isUpToDate {
                CancelButton(action: close)
                Button(plan.pending == nil ? "Update" : "Finish Update") {
                    close()
                    Task { await workbench.updateApp(app, on: bench) }
                }
                .keyboardShortcut(.defaultAction)
            } else if plan == nil && error == nil {
                CancelButton(action: close)
            } else {
                DoneButton(action: close)
            }
        }
        .task {
            switch await workbench.updatePlan(app, on: bench) {
            case .success(let p): plan = p
            case .failure(let e): error = e.message
            }
        }
    }
}
