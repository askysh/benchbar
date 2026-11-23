import SwiftUI

/// One bench in the BenchBar window.
struct BenchPage: View {
    let store: BenchStore
    let workbench: Workbench
    let bench: BenchModel
    @Bindable var router: WindowRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // the column of the tab's Form below, which centers past its widest
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 16).padding(.bottom, 10)
                Picker("", selection: $router.benchTab) {
                    ForEach(BenchTab.visible(lanRooms: Labs.shared.isOn(.lanRooms), sharingAvailable: ShareCenter.shared.showsTab(for: bench.path))) { Text($0.rawValue).tag($0) }
                }
                .pageTabs()
                .labelsHidden()
                // the first tab drew a focus ring when the window opened, and the clicked one after
                .focusEffectDisabled()
                ChangeResultBanner(workbench: workbench, scope: bench.path)
                    .padding(.top, 10)
            }
            .frame(maxWidth: WindowMetrics.groupedFormMaxWidth, alignment: .leading)
            .padding(.horizontal, WindowMetrics.paneInset)
            .frame(maxWidth: .infinity)
            Group {
                switch router.benchTab {
                case .overview: BenchOverview(store: store, workbench: workbench, bench: bench, router: router)
                case .sites: BenchSites(store: store, workbench: workbench, bench: bench, router: router)
                case .apps: BenchApps(store: store, workbench: workbench, bench: bench)
                case .health: BenchHealth(store: store, workbench: workbench, bench: bench, router: router)
                case .sharing:
                    if Labs.shared.isOn(.lanRooms), let share = ShareCenter.shared.store(for: bench.path) { SharingTab(bench: bench, share: share) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // a success banner belongs to the tab it came from; a failure stays until dismissed
        .onChange(of: router.benchTab) {
            if workbench.result?.succeeded == true { workbench.result = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(bench.name).font(.title2.weight(.semibold))
                Text(bench.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let guidance = bench.guidance {
                    GuidanceLine(guidance: guidance, enabled: guidance.action == .start ? store.controls(for: bench).canStart : store.busyBench == nil) { act($0) }
                }
            }
            Spacer()
            if let activity = bench.activity {
                ProgressView().controlSize(.small)
                Text(activity).font(.caption).foregroundStyle(.secondary)
            }
            StatePill(state: bench.state, text: BenchText.headline(bench.state, reason: bench.machine.stopReason,
                                                                    exitCode: bench.status?.lastExitCode,
                                                                    ready: bench.status?.ready))
        }
    }
}

extension BenchPage {
    /// The guidance line's action: the same ones the buttons and the popover have.
    fileprivate func act(_ action: BenchGuidance.Action) {
        switch action {
        case .start: Task { await store.perform(.up, on: bench) }
        case .viewHealth: router.benchTab = .health
        case .repair:
            router.repairRequested = true
            router.benchTab = .health
        case .reviewPortConflict, .setUpManagement:
            router.startAfterSetup = action == .reviewPortConflict
            router.setupRequest = bench.path
            router.benchTab = .overview
        }
    }
}

// MARK: overview

struct BenchOverview: View {
    let store: BenchStore
    let workbench: Workbench
    let bench: BenchModel
    @Bindable var router: WindowRouter
    @State private var schedulerChange: Bool?
    @State private var portSetup: PortSetupRun?
    @State private var servicing = false
    @State private var runningCommand = false
    @State private var tidying: TidyRoute?

    private var controls: BenchControls { store.controls(for: bench) }
    /// What this CLI lists (`commands --json`): a button of a newer command shows only when it is there.
    private var catalog: CommandCatalog? { workbench.commandState.catalog }

    var body: some View {
        let ports = bench.status?.ports ?? bench.summary.ports
        Form {
            Section {
                controlRow
                if let since = bench.upSince {
                    Uptime(since: since) { LabeledContent("Up for", value: $0) }
                }
                if let error = bench.lastError ?? bench.refreshError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    if let refusal = LeaseRefusal.parse(error), let action = bench.leaseRefusedAction {
                        LeaseBreakRow(lease: refusal, title: action.title, canBreak: store.canChange(bench)) {
                            Task { await store.perform(action, on: bench, breakLease: true) }
                        }
                    }
                }
            }
            if bench.runningSince != nil {
                ResourceSection(bench: bench)
            }
            if bench.summary.lockFile != nil || catalog?.has("lock") == true {
                LockSection(workbench: workbench, bench: bench, store: store)
            }
            LeaseSection(workbench: workbench, bench: bench)
            OperationsSection(workbench: workbench, bench: bench)
            Section {
                PortConflictAction(store: store, bench: bench)
                LabeledContent("Default site", value: bench.summary.site)
                LabeledContent("Web", value: bench.status?.webURL ?? bench.summary.webURL)
                LabeledContent("Socket.IO port", value: String(ports.socketio))
                LabeledContent("Redis ports", value: "\(ports.redisQueue) (queue), \(ports.redisCache) (cache)")
                LabeledContent("Agent", value: bench.summary.label)
            } header: {
                HStack {
                    Text("Site and ports")
                    Spacer()
                    Button("Port Settings & Setup…") {
                        let run = PortSetupRun(summaries: [bench.summary], store: store, opensSettings: true)
                        portSetup = run
                        Task { await run.loadPlan() }
                    }
                    .disabled(store.busyBench != nil)
                }
            }
            Section("Background jobs") {
                Toggle(isOn: Binding(get: { bench.schedulerOn ?? false }, set: { schedulerChange = $0 })) {
                    Text("Scheduler")
                    Text(bench.schedulerOn == nil ? "Needs benchbar 0.4 or later"
                         : "Runs scheduled jobs (bench schedule) in the background. Changing it restarts a running bench.")
                }
                .disabled(bench.schedulerOn == nil || !store.canChange(bench))
                if catalog?.has("autostart") == true || bench.status?.autostart != nil, !bench.needsService {
                    Toggle(isOn: Binding(get: { workbench.autostartSetting(for: bench) ?? false },
                                         set: { on in Task { await workbench.setAutostart(on, on: bench) } })) {
                        Text("Start after login")
                        Text(workbench.autostartSetting(for: bench) == nil ? "Reading the setting…"
                             : "The bench comes back after you log in, if it was running when you logged out.")
                    }
                    .disabled(workbench.autostartSetting(for: bench) == nil || !store.canChange(bench))
                }
                if catalog?.has("service") == true {
                    LabeledContent {
                        Button(bench.needsService ? "Install Service…" : "Refresh Service…") { servicing = true }
                            .disabled(!store.canChange(bench))
                    } label: {
                        Text("Service")
                        Text(bench.needsService ? "Not installed. Shows its plan first." : "Writes the agent and runner files again. Shows its plan first.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $portSetup) { run in PortSetupSheet(run: run) { portSetup = nil } }
        .sheet(isPresented: $servicing) { ServiceSheet(workbench: workbench, bench: bench) { servicing = false } }
        .sheet(isPresented: $runningCommand) { RunSheet(workbench: workbench, bench: bench) { runningCommand = false } }
        .sheet(item: $tidying) { route in
            switch route {
            case .tidy: TidySheet(workbench: workbench, bench: bench, removeExpired: { tidying = .plan(.gc) }) { tidying = nil }
            case .plan(let action): TidyPlanSheet(workbench: workbench, bench: bench, action: action) { tidying = nil }
            }
        }
        .task { openRequestedSetup() }
        .task(id: store.stamp(for: bench)) {
            await workbench.loadCommands()
            await workbench.showAutostart(bench)
        }
        .task { await workbench.pollLeases(bench) }
        .task { await workbench.pollOps(bench) }
        .onChange(of: router.setupRequest) { _, _ in openRequestedSetup() }
        .alert(schedulerChange == true ? "Run the scheduler for \(bench.name)?" : "Stop the scheduler for \(bench.name)?",
               isPresented: Binding(get: { schedulerChange != nil }, set: { if !$0 { schedulerChange = nil } })) {
            Button(schedulerChange == true ? "Turn On and Restart" : "Turn Off and Restart") {
                guard let on = schedulerChange else { return }
                schedulerChange = nil
                Task { await store.setScheduler(on, on: bench) }
            }
            Button("Cancel", role: .cancel) { schedulerChange = nil }
        } message: {
            Text("BenchBar runs benchbar service \(schedulerChange == true ? "--with-schedule" : "--without-schedule"), then restarts the bench if it is running.")
        }
    }

    /// Start, stop and restart side by side, the site as the main action,
    /// the editor beside it and the rest in the "…" menu. Before the bench
    /// is managed, Set Up Management… is the main action instead. Where
    /// "Open in VS Code" does not fit whole, it moves into the "…" menu.
    private var controlRow: some View {
        ViewThatFits(in: .horizontal) {
            controls(editorInMenu: false)
            controls(editorInMenu: true)
        }
    }

    @ViewBuilder private func controls(editorInMenu: Bool) -> some View {
        let defaultNeedsHosts = bench.siteRows.first(where: \.isDefault)?.needsHosts == true
        let editor = store.settings.editor
        HStack(spacing: WindowMetrics.rowSpacing) {
            if bench.needsService {
                Button("Set Up Management…") {
                    router.startAfterSetup = false
                    router.setupRequest = bench.path
                }
                .primaryAction()
                .disabled(store.busyBench != nil)
            } else {
                // three titled buttons: a control group draws bare icons
                HStack(spacing: WindowMetrics.rowSpacing) {
                    Button { Task { await store.perform(.up, on: bench) } } label: { Label("Start", systemImage: "play.fill") }
                        .disabled(!controls.canStart)
                    Button { Task { await store.perform(.down, on: bench) } } label: { Label("Stop", systemImage: "stop.fill") }
                        .disabled(!controls.canStop)
                    Button { Task { await store.perform(.restart, on: bench) } } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        .disabled(!controls.canRestart)
                }
                .fixedSize()
            }
            Spacer(minLength: WindowMetrics.rowSpacing)
            if !editorInMenu {
                editorButton(editor).fixedSize()
            }
            if let defaultRow = bench.siteRows.first(where: \.isDefault) {
                OpenAsMenu(store: store, bench: bench, row: defaultRow) {
                    router.findUserRequest = FindUserRequest(bench: bench.path, site: defaultRow.name)
                    router.benchTab = .sites
                }
                .fixedSize()
            }
            Button(defaultNeedsHosts ? "Set Up Site…" : "Open Site") {
                if defaultNeedsHosts { router.benchTab = .sites }
                else { Workspace.openSite(bench) }
            }
            .primaryAction(!bench.needsService)
            .disabled(bench.state != .running && !defaultNeedsHosts)
            .fixedSize()
            MoreMenu(help: editorInMenu ? "The editor, console, database, Finder and the bench path" : "Console, database, Finder and the bench path") {
                if editorInMenu {
                    editorButton(editor)
                    Divider()
                }
                if catalog?.hasFlag("up", "--services-only") == true {
                    servicesItems
                    Divider()
                }
                Button { Workspace.openShell(.console, site: bench.summary.site, bench: bench, store: store) } label: {
                    Label("Open Console", systemImage: "terminal")
                }
                .help("bench --site \(bench.summary.site) console, in Terminal")
                Button { Workspace.openShell(.db, site: bench.summary.site, bench: bench, store: store) } label: {
                    Label("Open Database", systemImage: "cylinder")
                }
                .help("bench --site \(bench.summary.site) mariadb, in Terminal, with the site's own database user")
                if catalog?.has("watch") == true {
                    Button { Workspace.openWatch(bench: bench, store: store) } label: {
                        Label("Watch Assets in Terminal", systemImage: "eye")
                    }
                    .help("benchbar watch, in Terminal: rebuilds the assets while you edit JS or CSS. Close the window to stop it.")
                }
                if workbench.offersRun {
                    Button { runningCommand = true } label: {
                        Label("Run Bench Command…", systemImage: "terminal.fill")
                    }
                    .disabled(!store.canChange(bench))
                    .help("One command of benchbar's allow list (migrate, build, doctor and more). A change shows its plan first.")
                }
                tidyItems
                Divider()
                Button("Show in Finder", systemImage: "folder") { Workspace.openFolder(bench) }
                Button("Copy Path", systemImage: "doc.on.doc") { Workspace.copy(bench.path) }
            }
        }
    }

    /// The end of a bench's life (#183), each entry only when the CLI lists its command. A change shows its plan first.
    @ViewBuilder private var tidyItems: some View {
        let busy = !store.canChange(bench)
        if workbench.offersTidy || workbench.offers(.removeService) || workbench.offers(.forget) || workbench.offers(.remove) { Divider() }
        if workbench.offersTidy {
            Button { tidying = .tidy } label: { Label("Tidy Up…", systemImage: "sparkles") }
                .help("Scratch benches, the ones that expired, the databases no site refers to and the hosts lines no bench uses")
        }
        if workbench.offers(.removeService), !bench.needsService {
            Button { tidying = .plan(.removeService) } label: { Label("Remove Service…", systemImage: "gearshape.slash") }
                .disabled(busy)
                .help("uninstall-service for this bench: stops it and removes its background service. Shows its plan first.")
        }
        if workbench.offers(.forget) {
            Button { tidying = .plan(.forget) } label: { Label("Forget Bench…", systemImage: "eye.slash") }
                .disabled(busy)
                .help("bench forget: takes the bench out of benchbar's list. The folder, sites and databases stay.")
        }
        if workbench.offers(.remove) {
            Button { tidying = .plan(.remove) } label: { Label("Remove Bench…", systemImage: "trash") }
                .disabled(busy)
                .help("bench remove: backs up and drops its sites, then moves the folder aside. Asks for the folder name.")
        }
    }

    /// Start Services Only and Stop Services, for a bench that is not running, with or without the service
    /// installed: no plan, the click is the decision.
    /// The status says whether each Redis answers; without it (an older CLI) both are offered.
    @ViewBuilder private var servicesItems: some View {
        let redis = bench.status?.redis
        // `up --services-only` needs no installed service (the CLI says so), and the state of a bench with none is not "stopped"
        let notRunning = ServicesOnly.notRunning(needsService: bench.needsService, state: bench.state, processesRunning: bench.status?.processesRunning)
        let stopped = notRunning && store.canChange(bench)
        Button { Task { await workbench.setServices(true, on: bench) } } label: {
            Label("Start Services Only", systemImage: "externaldrive.badge.plus")
        }
        .disabled(!stopped || redis?.allRunning == true)
        .help("up --services-only: the bench's Redis and nothing else, for a restore or a migrate")
        Button { Task { await workbench.setServices(false, on: bench) } } label: {
            Label("Stop Services", systemImage: "externaldrive.badge.minus")
        }
        .disabled(!stopped || redis?.anyRunning == false)
        .help("down: stops the Redis that Start Services Only started")
    }

    private func editorButton(_ editor: Editor?) -> some View {
        Button { if let editor { Workspace.openInEditor(bench, editor: editor) } } label: {
            Label(editor.map { "Open in \($0.name)" } ?? "Open in Editor", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .disabled(editor == nil)
        .help(editor == nil ? "Install VS Code or Cursor to open the bench folder in it." : bench.path)
    }

    private func openRequestedSetup() {
        guard router.setupRequest == bench.path else { return }
        let start = router.startAfterSetup
        router.setupRequest = nil
        router.startAfterSetup = false
        let run = PortSetupRun(summaries: [bench.summary], store: store, startAfterSetup: start)
        portSetup = run
        Task { await run.loadPlan() }
    }
}

// MARK: sites

struct BenchSites: View {
    let store: BenchStore
    let workbench: Workbench
    let bench: BenchModel
    /// Set by the popover's hosts hint: the Add Hosts Lines sheet opens at once.
    var router: WindowRouter?
    @State private var addingSite = false
    @State private var hosts: HostsRun?
    @State private var dropping: String?
    @State private var restoring: String?
    @State private var snapshotting: String?
    @State private var pulling = false
    @State private var findingUser: String?
    @State private var allowingOpenAs: String?

    private var busy: Bool { !store.canChange(bench) }

    var body: some View {
        let rows = bench.siteRows
        Form {
            Section {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row.isDefault ? "star.fill" : "globe")
                            .foregroundStyle(row.isDefault ? .yellow : .secondary)
                            .accessibilityLabel(row.isDefault ? "Default site" : "Site")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                            Text(row.needsHosts ? "no /etc/hosts line yet" : row.url)
                                .font(.caption).foregroundStyle(row.needsHosts ? .orange : .secondary)
                            if let last = workbench.backups(of: row.name, on: bench)?.backups.first {
                                LastBackupLine(backup: last)
                            }
                            if let line = OpenAsMenuModel.statusLine(row) {
                                Text(line.text).font(.caption).foregroundStyle(line.warning ? .orange : .secondary)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                        Spacer()
                        if Workbench.isBackingUp(row.name, activity: bench.activity) {
                            ProgressView().controlSize(.small)
                        }
                        OpenAsMenu(store: store, bench: bench, row: row) { findingUser = row.name }
                        Button(row.needsHosts ? "Set Up…" : "Open") {
                            if row.needsHosts { openHosts() }
                            else { Workspace.open(row.url) }
                        }
                        .disabled(!row.needsHosts && bench.state != .running)
                        SiteMenu(workbench: workbench, bench: bench, row: row, busy: busy, onlySite: rows.count == 1,
                                 openAs: { turnOpenAs(row) }, restore: { restoring = row.name },
                                 snapshots: { snapshotting = row.name }) { dropping = row.name }
                    }
                }
            } header: {
                HStack {
                    Text("Sites")
                    Spacer()
                    Button { pulling = true } label: { Label("Pull…", systemImage: "arrow.down.circle") }
                        .help("Copy a production site, or a downloaded backup, into a new site")
                        .disabled(busy)
                    Button { addingSite = true } label: { Label("Add Site…", systemImage: "plus") }
                        .primaryAction()
                        .disabled(busy)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The default site is the one benchup waits for, the runner pings and ⌘O opens.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if rows.count == 1 {
                Section {
                    EmptyStateBlock(symbol: "globe", title: "One site so far",
                                    line: "A second site shares this bench and its MariaDB, with only Frappe installed.",
                                    actions: [("Add Site…", { addingSite = true })], disabled: busy)
                }
            }
            if SiteRow.hostsFix(rows, bench: bench.path) != nil {
                Section {
                    LabeledContent {
                        Button("Add Hosts Lines…", action: openHosts)
                            .disabled(busy)
                            .help("Asks for your password")
                    } label: {
                        Text("Some site names need a hosts line")
                        Text("A local /etc/hosts entry makes the name open in your browser. Asks for your password.")
                    }
                } header: {
                    Text("Hosts")
                }
            }
        }
        .formStyle(.grouped)
        .task(id: bench.siteRows.map(\.name)) { await workbench.loadBackups(bench) }
        .task { openRequestedHosts(); openRequestedFindUser() }
        .onChange(of: router?.hostsRequest) { openRequestedHosts() }
        .onChange(of: router?.findUserRequest) { openRequestedFindUser() }
        .alert("Allow Open as on \(allowingOpenAs ?? "")?",
               isPresented: Binding(get: { allowingOpenAs != nil }, set: { if !$0 { allowingOpenAs = nil } })) {
            Button("Allow Open as") {
                guard let site = allowingOpenAs else { return }
                allowingOpenAs = nil
                Task { await workbench.setOpenAs(true, site: site, on: bench) }
            }
            Button("Cancel", role: .cancel) { allowingOpenAs = nil }
        } message: {
            Text(OpenAsMenuModel.allowMessage)
        }
        .sheet(item: $hosts) { run in HostsSheet(run: run) { hosts = nil } }
        .sheet(item: Binding(get: { findingUser.map(FindUserTarget.init) }, set: { findingUser = $0?.site })) { target in
            if let row = rows.first(where: { $0.name == target.site }) {
                FindUserSheet(store: store, bench: bench, row: row) { findingUser = nil }
            }
        }
        .sheet(item: Binding(get: { dropping.map(DropTarget.init) }, set: { dropping = $0?.site })) { target in
            SiteDropSheet(workbench: workbench, bench: bench, site: target.site) { dropping = nil }
        }
        .sheet(isPresented: $addingSite) {
            AddSiteSheet(workbench: workbench, bench: bench) { addingSite = false }
        }
        .sheet(item: Binding(get: { restoring.map(DropTarget.init) }, set: { restoring = $0?.site })) { target in
            SiteRestoreSheet(workbench: workbench, bench: bench, site: target.site) { restoring = nil }
        }
        .sheet(item: Binding(get: { snapshotting.map(DropTarget.init) }, set: { snapshotting = $0?.site })) { target in
            SnapshotsSheet(workbench: workbench, bench: bench, site: target.site) { snapshotting = nil }
        }
        .sheet(isPresented: $pulling) {
            PullSheet(workbench: workbench, bench: bench) { pulling = false }
        }
    }
}

extension BenchSites {
    fileprivate func openHosts() {
        hosts = HostsRun(bench: bench, store: store)
    }

    /// Turning it on asks first; turning it off does not.
    fileprivate func turnOpenAs(_ row: SiteRow) {
        if row.openAsEnabled == true {
            Task { await workbench.setOpenAs(false, site: row.name, on: bench) }
        } else {
            allowingOpenAs = row.name
        }
    }

    fileprivate func openRequestedFindUser() {
        guard let request = router?.findUserRequest, request.bench == bench.path else { return }
        router?.findUserRequest = nil
        findingUser = request.site
    }

    fileprivate func openRequestedHosts() {
        guard router?.hostsRequest == bench.path else { return }
        router?.hostsRequest = nil
        openHosts()
    }
}

private struct DropTarget: Identifiable {
    var site: String
    var id: String { site }
}

private struct FindUserTarget: Identifiable {
    var site: String
    var id: String { site }
}

/// "Backed up 2 hours ago, 5.0 MB, with files" and Show in Finder.
struct LastBackupLine: View {
    let backup: SiteBackup
    @Environment(\.pinnedNow) private var pinnedNow

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.caption).foregroundStyle(.secondary)
            Button("Show in Finder") { Workspace.reveal(backup.parts) }
                .buttonStyle(.link).font(.caption)
        }
    }

    private var text: String {
        let size = ByteCountFormatter.string(fromByteCount: backup.sizeBytes, countStyle: .file)
        // a clock that is a little behind must not say "in 2 minutes"
        let when = backup.time.map { "Backed up " + Self.age(of: $0, now: pinnedNow ?? .now) } ?? "Backed up \(backup.stamp)"
        return "\(when), \(size)\(backup.withFiles ? ", with files" : "")"
    }

    /// "2 hours ago"; a clock that is a little behind must not say "in 2 minutes".
    static func age(of time: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: min(time, now), relativeTo: now)
    }
}

/// The per site actions that do not fit a button: the default, backups,
/// the shells and drop.
struct SiteMenu: View {
    let workbench: Workbench
    let bench: BenchModel
    let row: SiteRow
    let busy: Bool
    let onlySite: Bool
    let openAs: () -> Void
    let restore: () -> Void
    let snapshots: () -> Void
    let drop: () -> Void

    var body: some View {
        MoreMenu(help: "Make \(row.name) the default, back it up, snapshot it, restore it or drop it") {
            if !row.isDefault {
                Button("Make Default") { Task { await workbench.setDefaultSite(row.name, on: bench) } }
                Divider()
            }
            Button("Back Up") { Task { await workbench.backUpSite(row.name, withFiles: false, on: bench) } }
            Button("Back Up with Files") { Task { await workbench.backUpSite(row.name, withFiles: true, on: bench) } }
            if let list = workbench.backups(of: row.name, on: bench) {
                Button("Show Backups in Finder") {
                    if let last = list.backups.first { Workspace.reveal([last.path]) }
                    else { Workspace.open(URL(fileURLWithPath: list.folder).absoluteString) }
                }
                .disabled(list.backups.isEmpty)
            }
            Button("Restore a Backup…", action: restore)
                .disabled(workbench.backups(of: row.name, on: bench)?.backups.isEmpty ?? true)
            Button("Snapshots…", action: snapshots)
                .help("Take a snapshot, see the snapshots of \(row.name), roll it back to one")
            Divider()
            Button("Open Console") { Workspace.openShell(.console, site: row.name, bench: bench, store: workbench.store) }
            Button("Open Database") { Workspace.openShell(.db, site: row.name, bench: bench, store: workbench.store) }
            if let enabled = row.openAsEnabled {
                Divider()
                Button(enabled ? "Turn Off Open as" : "Allow Open as…", action: openAs)
            }
            Divider()
            Button("Drop Site…", role: .destructive, action: drop)
                .disabled(onlySite)
        }
        .disabled(busy)
    }
}

/// Fill in the site, Review reads the CLI's plan (`site add --dry-run
/// --json`), Add Site runs it by its token. A token the CLI refuses (the
/// bench changed since) shows here, with Review Again; any other failure
/// closes the sheet and the change banner has it.
struct AddSiteSheet: View {
    /// What the sheet starts with: empty for a person, filled for a render.
    struct Start {
        var name = ""
        var password = ""
        var flow = PlanReviewFlow<SiteAddPlan>()
    }

    let workbench: Workbench
    let bench: BenchModel
    let close: () -> Void
    @State private var name: String
    @State private var password: String
    @State private var confirm: String
    @State private var flow: PlanReviewFlow<SiteAddPlan>

    init(workbench: Workbench, bench: BenchModel, start: Start = Start(), close: @escaping () -> Void) {
        self.workbench = workbench
        self.bench = bench
        self.close = close
        _name = State(initialValue: start.name)
        _password = State(initialValue: start.password)
        _confirm = State(initialValue: start.password)
        _flow = State(initialValue: start.flow)
    }

    private var nameValid: Bool { SiteName.isValid(name) && !bench.siteRows.contains { $0.name == name } }
    private var passwordValid: Bool { !password.isEmpty && password == confirm }

    private var phase: SheetPhase {
        switch flow.stage {
        case .form:
            if let error = flow.readError { .failed(error, title: "\(name) cannot be added") } else { .ready }
        case .reading: .loading("Reading the plan from benchbar…")
        case .reviewing: .ready
        case .applying: .running("Creating \(name)…")
        case .stale: .failed("Nothing was changed. Review the plan again to see what it is now.", title: "The bench changed since this plan was shown")
        }
    }

    var body: some View {
        SheetScaffold("Add a Site to \(bench.name)",
                      explanation: flow.plan == nil
                          ? "A new site on the same MariaDB, with only Frappe installed. Add apps from the Apps tab afterwards."
                          : "Nothing has run yet. These are the steps; Add Site runs exactly this plan.",
                      phase: phase, width: flow.plan == nil ? .regular : .wide) {
            if let plan = flow.plan {
                SiteAddPlanView(plan: plan)
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
                    .disabled(!nameValid || !passwordValid || flow.stage == .reading)
            case .reviewing(let plan):
                CancelButton(action: close)
                Button("Add Site") { apply() }
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

    private var isStale: Bool { if case .stale = flow.stage { true } else { false } }

    @ViewBuilder private var form: some View {
        Form {
            TextField("Site name", text: $name, prompt: Text("mysite"))
            if !name.isEmpty && !SiteName.isValid(name) {
                Text(SiteName.rule).font(.caption).foregroundStyle(.red)
            }
            SecureField("Administrator password", text: $password)
            SecureField("Confirm password", text: $confirm)
        }
        .formStyle(.columns)
        SheetNote("The password goes to the benchbar process only, never on a command line or to disk. The MariaDB password comes from your Keychain.")
    }

    private func review() {
        guard flow.review() else { return }
        Task { flow.read(await workbench.addSitePlan(name, on: bench)) }
    }

    private func apply() {
        guard let plan = flow.apply() else { return }
        Task {
            let error = await workbench.addSite(name, adminPassword: password, token: plan.token, on: bench)
            // a stale token is answered here, with Review Again, not in the banner
            if flow.finish(error: error) { close() } else { workbench.result = nil }
        }
    }
}

// MARK: lockfile

/// "In sync" or "N differences" against the bench's benchbar.toml, from `lock check --json` (read only),
/// and the two changes the lockfile has: Write Lock File and Apply. Each shows the CLI's own plan in a
/// sheet first; nothing runs before the click on its button.
struct LockSection: View {
    let workbench: Workbench
    let bench: BenchModel
    let store: BenchStore
    @State private var showDrift = false
    @State private var sheet: LockSheet.Kind?

    private var busy: Bool { !store.canChange(bench) }

    var body: some View {
        let check = workbench.lockChecks[bench.path]
        Section {
            HStack(spacing: 8) {
                if bench.summary.lockFile == nil {
                    Image(systemName: "doc.badge.plus").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(LockText.noFile).foregroundStyle(.secondary)
                } else if workbench.checkingLock.contains(bench.path) && check == nil {
                    ProgressView().controlSize(.small)
                    Text("Comparing with the lockfile…").foregroundStyle(.secondary)
                } else if let check {
                    Image(systemName: check.inSync ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(check.inSync ? .green : .orange)
                        .accessibilityLabel(check.inSync ? "In sync" : "Differences")
                    Text(LockText.badge(check))
                } else if let error = workbench.lockErrors[bench.path] {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel("Error")
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                if bench.summary.lockFile != nil {
                    Button("Check Again") { Task { await workbench.checkLock(bench) } }
                        .disabled(workbench.checkingLock.contains(bench.path))
                    Button("Apply…") { sheet = .apply }
                        .disabled(busy || check?.inSync == true)
                        .help("Shows what lock apply would do to the apps, then runs it when you confirm")
                }
                Button("Write Lock File…") { sheet = .write }
                    .disabled(busy)
                    .help("Shows the file lock write would write from this bench, then writes it when you confirm")
            }
            if let check, !check.drift.isEmpty {
                DisclosureGroup(isExpanded: $showDrift) {
                    ForEach(check.drift) { drift in
                        Label(drift.text, systemImage: drift.level == "fail" ? "xmark.circle" : "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(drift.level == "fail" ? .red : .primary)
                            .textSelection(.enabled)
                    }
                } label: {
                    Text("Differences").font(.callout)
                }
            }
        } header: {
            Text("Lockfile")
        } footer: {
            Text(LockText.footer(bench.summary.lockFile))
        }
        .task(id: bench.path) { await workbench.checkLock(bench) }
        // after a change (an app added or updated) the answer may differ
        .onChange(of: workbench.result) { _, result in
            if result?.scope == bench.path { Task { await workbench.checkLock(bench) } }
        }
        .sheet(item: $sheet) { kind in
            LockSheet(workbench: workbench, bench: bench, kind: kind) { sheet = nil }
        }
    }
}

nonisolated enum LockText {
    static func badge(_ check: LockCheck) -> String {
        if check.inSync { return "In sync" }
        let n = check.drift.count
        return n == 1 ? "1 difference" : "\(n) differences"
    }

    static let noFile = "No lockfile for this bench yet."

    static func footer(_ path: String?) -> String {
        guard let path else { return "benchbar.toml pins the apps and sites of this bench for the team. Write Lock File makes one from this bench." }
        return "Compared with \(path). Apply brings the apps in line; no site is touched."
    }
}
