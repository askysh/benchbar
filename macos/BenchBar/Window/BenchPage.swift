import SwiftUI

/// One bench in the BenchBar window.
struct BenchPage: View {
    let store: BenchStore
    let workbench: Workbench
    let bench: BenchModel
    @Bindable var router: WindowRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
            Picker("", selection: $router.benchTab) {
                ForEach(BenchTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pageTabs()
            .labelsHidden()
            .padding(.horizontal, 20)
            ChangeResultBanner(workbench: workbench, scope: bench.path)
                .padding(.horizontal, 20).padding(.top, 10)
            Group {
                switch router.benchTab {
                case .overview: BenchOverview(store: store, workbench: workbench, bench: bench, router: router)
                case .sites: BenchSites(store: store, workbench: workbench, bench: bench)
                case .apps: BenchApps(store: store, workbench: workbench, bench: bench)
                case .health: BenchHealth(store: store, bench: bench, router: router)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(bench.name).font(.title2.weight(.semibold))
                Text(bench.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if let activity = bench.activity {
                ProgressView().controlSize(.small)
                Text(activity).font(.caption).foregroundStyle(.secondary)
            }
            StatePill(state: bench.state, text: BenchText.headline(bench.state, reason: bench.machine.stopReason,
                                                                    exitCode: bench.status?.lastExitCode))
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

    private var controls: BenchControls { store.controls(for: bench) }

    var body: some View {
        let ports = bench.status?.ports ?? bench.summary.ports
        Form {
            Section {
                HStack(spacing: 8) {
                    if bench.needsService {
                        Button("Set Up Management…") {
                            router.startAfterSetup = false
                            router.setupRequest = bench.path
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.busyBench != nil)
                    } else {
                        Button { Task { await store.perform(.up, on: bench) } } label: { Label("Start", systemImage: "play.fill") }
                            .disabled(!controls.canStart)
                        Button { Task { await store.perform(.down, on: bench) } } label: { Label("Stop", systemImage: "stop.fill") }
                            .disabled(!controls.canStop)
                        Button { Task { await store.perform(.restart, on: bench) } } label: { Label("Restart", systemImage: "arrow.clockwise") }
                            .disabled(!controls.canRestart)
                    }
                    Spacer()
                    Button(bench.siteRows.first(where: \.isDefault)?.needsHosts == true ? "Set Up Site…" : "Open Site") {
                        if bench.siteRows.first(where: \.isDefault)?.needsHosts == true { router.benchTab = .sites }
                        else { Workspace.openSite(bench) }
                    }
                    .disabled(bench.state != .running && bench.siteRows.first(where: \.isDefault)?.needsHosts != true)
                    Button("Show in Finder") { Workspace.openFolder(bench) }
                }
                HStack(spacing: 8) {
                    let editor = store.settings.editor
                    Button { if let editor { Workspace.openInEditor(bench, editor: editor) } } label: {
                        Label(editor.map { "Open in \($0.name)" } ?? "Open in Editor", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .disabled(editor == nil)
                    .help(editor == nil ? "Install VS Code or Cursor to open the bench folder in it." : bench.path)
                    Spacer()
                    Button { Workspace.openShell(.console, site: bench.summary.site, bench: bench, store: store) } label: {
                        Label("Console", systemImage: "terminal")
                    }
                    .help("bench --site \(bench.summary.site) console, in Terminal")
                    Button { Workspace.openShell(.db, site: bench.summary.site, bench: bench, store: store) } label: {
                        Label("Database", systemImage: "cylinder")
                    }
                    .help("bench --site \(bench.summary.site) mariadb, in Terminal, with the site's own database user")
                }
                if let since = bench.runningSince {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        LabeledContent("Up for", value: BenchText.uptime(since: since, now: context.date))
                    }
                }
                if let error = bench.lastError ?? bench.refreshError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            if bench.runningSince != nil {
                ResourceSection(bench: bench)
            }
            if bench.summary.lockFile != nil {
                LockSection(workbench: workbench, bench: bench)
            }
            Section("Site and ports") {
                PortConflictAction(store: store, bench: bench)
                Button("Port Settings & Setup…") {
                    let run = PortSetupRun(summaries: [bench.summary], store: store)
                    portSetup = run
                    Task { await run.loadPlan() }
                }.disabled(store.busyBench != nil)
                LabeledContent("Default site", value: bench.summary.site)
                LabeledContent("Web", value: bench.status?.webURL ?? bench.summary.webURL)
                LabeledContent("Socket.IO port", value: String(ports.socketio))
                LabeledContent("Redis ports", value: "\(ports.redisQueue) (queue), \(ports.redisCache) (cache)")
                LabeledContent("Agent", value: bench.summary.label)
            }
            Section("Background jobs") {
                Toggle(isOn: Binding(get: { bench.schedulerOn ?? false }, set: { schedulerChange = $0 })) {
                    Text("Scheduler")
                    Text(bench.schedulerOn == nil ? "Needs benchbar 0.4 or later"
                         : "Runs scheduled jobs (bench schedule) in the background. Changing it restarts a running bench.")
                }
                .disabled(bench.schedulerOn == nil || !controlsIdle)
            }

        }
        .formStyle(.grouped)
        .sheet(item: $portSetup) { run in PortSetupSheet(run: run) { portSetup = nil } }
        .task { openRequestedSetup() }
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

    private func openRequestedSetup() {
        guard router.setupRequest == bench.path else { return }
        let start = router.startAfterSetup
        router.setupRequest = nil
        router.startAfterSetup = false
        let run = PortSetupRun(summaries: [bench.summary], store: store, startAfterSetup: start)
        portSetup = run
        Task { await run.loadPlan() }
    }

    private var controlsIdle: Bool {
        bench.pending == nil && !bench.isChangingScheduler && bench.activity == nil && !store.waitsForOtherBench(bench)
    }
}

// MARK: sites

struct BenchSites: View {
    let store: BenchStore
    let workbench: Workbench
    let bench: BenchModel
    @State private var addingSite = false
    @State private var showHostsInstructions = false
    @State private var dropping: String?

    private var busy: Bool {
        bench.pending != nil || bench.isChangingScheduler || bench.activity != nil || store.waitsForOtherBench(bench)
    }

    var body: some View {
        let rows = bench.siteRows
        Form {
            Section {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row.isDefault ? "star.fill" : "globe")
                            .foregroundStyle(row.isDefault ? .yellow : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                            Text(row.needsHosts ? "no /etc/hosts line yet" : row.url)
                                .font(.caption).foregroundStyle(row.needsHosts ? .orange : .secondary)
                            if let last = workbench.backups(of: row.name, on: bench)?.backups.first {
                                LastBackupLine(backup: last)
                            }
                        }
                        Spacer()
                        if bench.activity?.hasPrefix("Back up \(row.name)") == true {
                            ProgressView().controlSize(.small)
                        }
                        if !row.isDefault {
                            Button("Make Default") { Task { await workbench.setDefaultSite(row.name, on: bench) } }
                                .disabled(busy)
                        }
                        Button(row.needsHosts ? "Set Up…" : "Open") {
                            if row.needsHosts { showHostsInstructions = true }
                            else { Workspace.open(row.url) }
                        }
                        .disabled(!row.needsHosts && bench.state != .running)
                        SiteMenu(workbench: workbench, bench: bench, row: row, busy: busy,
                                 onlySite: rows.count == 1) { dropping = row.name }
                    }
                }
            } header: {
                HStack {
                    Text("Sites")
                    Spacer()
                    Button { addingSite = true } label: { Label("Add Site…", systemImage: "plus") }
                        .primaryAction()
                        .disabled(busy)
                }
            } footer: {
                Text("The default site is the one benchup waits for, the runner pings and ⌘O opens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let fix = SiteRow.hostsFix(rows, bench: bench.path) {
                Section("Hosts") {
                    Text("Some site names need a local hosts entry. This step requires your Mac password in Terminal.")
                        .font(.callout)
                    DisclosureGroup("Terminal instructions", isExpanded: $showHostsInstructions) {
                        HStack(alignment: .top) {
                            Text(fix).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button("Copy Command") { Workspace.copy(fix) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: bench.siteRows.map(\.name)) { await workbench.loadBackups(bench) }
        .sheet(item: Binding(get: { dropping.map(DropTarget.init) }, set: { dropping = $0?.site })) { target in
            SiteDropSheet(workbench: workbench, bench: bench, site: target.site) { dropping = nil }
        }
        .sheet(isPresented: $addingSite) {
            AddSiteSheet(bench: bench) { name, password in
                addingSite = false
                Task { await workbench.addSite(name, adminPassword: password, on: bench) }
            } cancel: { addingSite = false }
        }
    }
}

private struct DropTarget: Identifiable {
    var site: String
    var id: String { site }
}

/// "Backed up 2 hours ago, 5.0 MB, with files" and Show in Finder.
struct LastBackupLine: View {
    let backup: SiteBackup

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
        let when = backup.time.map { "Backed up " + min($0, .now).formatted(.relative(presentation: .named)) } ?? "Backed up \(backup.stamp)"
        return "\(when), \(size)\(backup.withFiles ? ", with files" : "")"
    }
}

/// The per site actions that do not fit a button: backups and drop.
struct SiteMenu: View {
    let workbench: Workbench
    let bench: BenchModel
    let row: SiteRow
    let busy: Bool
    let onlySite: Bool
    let drop: () -> Void

    var body: some View {
        Menu {
            Button("Back Up") { Task { await workbench.backUpSite(row.name, withFiles: false, on: bench) } }
            Button("Back Up with Files") { Task { await workbench.backUpSite(row.name, withFiles: true, on: bench) } }
            if let list = workbench.backups(of: row.name, on: bench) {
                Button("Show Backups in Finder") {
                    if let last = list.backups.first { Workspace.reveal([last.path]) }
                    else { Workspace.open(URL(fileURLWithPath: list.folder).absoluteString) }
                }
                .disabled(list.backups.isEmpty)
            }
            Divider()
            Button("Open Console") { Workspace.openShell(.console, site: row.name, bench: bench, store: workbench.store) }
            Button("Open Database") { Workspace.openShell(.db, site: row.name, bench: bench, store: workbench.store) }
            Divider()
            Button("Drop Site…", role: .destructive, action: drop)
                .disabled(onlySite)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(busy)
        .help("Back up or drop \(row.name)")
    }
}

struct AddSiteSheet: View {
    let bench: BenchModel
    let add: (String, String) -> Void
    let cancel: () -> Void
    @State private var name = ""
    @State private var password = ""
    @State private var confirm = ""

    private var nameValid: Bool { SiteName.isValid(name) && !bench.siteRows.contains { $0.name == name } }
    private var passwordValid: Bool { !password.isEmpty && password == confirm }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a site to \(bench.name)").font(.headline)
            Text("A new site on the same MariaDB, with only Frappe installed. Add apps from the Apps tab afterwards.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Site name", text: $name, prompt: Text("mysite"))
                if !name.isEmpty && !SiteName.isValid(name) {
                    Text("Lowercase letters, digits, '-' and '.' only.").font(.caption).foregroundStyle(.red)
                }
                SecureField("Administrator password", text: $password)
                SecureField("Confirm password", text: $confirm)
            }
            .formStyle(.grouped)
            Text("The password goes to the benchbar process only, never on a command line or to disk. The MariaDB password comes from your Keychain.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Add Site") { add(name, password) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!nameValid || !passwordValid)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

nonisolated enum SiteName {
    /// The CLI's own rule (fl_site_valid_name).
    static func isValid(_ name: String) -> Bool {
        guard let first = name.first, first.isLowercase || first.isNumber else { return false }
        return name.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" || $0 == "." }
    }
}

// MARK: lockfile

/// "In sync" or "N differences" against the bench's benchbar.toml, from
/// `lock check --json` (read only). No apply here: that is `benchbar lock
/// apply` in Terminal for now.
struct LockSection: View {
    let workbench: Workbench
    let bench: BenchModel
    @State private var showDrift = false

    var body: some View {
        let check = workbench.lockChecks[bench.path]
        Section {
            HStack(spacing: 8) {
                if workbench.checkingLock.contains(bench.path) && check == nil {
                    ProgressView().controlSize(.small)
                    Text("Comparing with the lockfile…").foregroundStyle(.secondary)
                } else if let check {
                    Image(systemName: check.inSync ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(check.inSync ? .green : .orange)
                    Text(LockText.badge(check))
                } else if let error = workbench.lockErrors[bench.path] {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Button("Check Again") { Task { await workbench.checkLock(bench) } }
                    .disabled(workbench.checkingLock.contains(bench.path))
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
            Text(LockText.footer(bench.summary.lockFile ?? ""))
        }
        .task(id: bench.path) { await workbench.checkLock(bench) }
        // after a change (an app added or updated) the answer may differ
        .onChange(of: workbench.result) { _, result in
            if result?.scope == bench.path { Task { await workbench.checkLock(bench) } }
        }
    }
}

nonisolated enum LockText {
    static func badge(_ check: LockCheck) -> String {
        if check.inSync { return "In sync" }
        let n = check.drift.count
        return n == 1 ? "1 difference" : "\(n) differences"
    }

    static func footer(_ path: String) -> String {
        "Compared with \(path). To bring the bench in line, run benchbar lock apply in Terminal."
    }
}
