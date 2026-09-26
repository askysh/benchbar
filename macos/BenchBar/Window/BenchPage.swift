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
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            ChangeResultBanner(workbench: workbench)
                .padding(.horizontal, 20).padding(.top, 10)
            Group {
                switch router.benchTab {
                case .overview: BenchOverview(store: store, bench: bench)
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
    let bench: BenchModel
    @State private var schedulerChange: Bool?

    private var controls: BenchControls {
        var cliReady = false
        if case .ready = store.cli { cliReady = true }
        return .make(state: bench.state, reason: bench.machine.stopReason, pending: bench.pending,
                     needsService: bench.needsService, cliReady: cliReady,
                     otherWork: bench.isChangingScheduler || bench.activity != nil || store.waitsForOtherBench(bench))
    }

    var body: some View {
        let ports = bench.status?.ports ?? bench.summary.ports
        Form {
            Section {
                HStack(spacing: 8) {
                    Button { Task { await store.perform(.up, on: bench) } } label: { Label("Start", systemImage: "play.fill") }
                        .disabled(!controls.canStart)
                    Button { Task { await store.perform(.down, on: bench) } } label: { Label("Stop", systemImage: "stop.fill") }
                        .disabled(!controls.canStop)
                    Button { Task { await store.perform(.restart, on: bench) } } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        .disabled(!controls.canRestart)
                    Spacer()
                    Button("Open Site") { Workspace.openSite(bench) }
                    Button("Show in Finder") { Workspace.openFolder(bench) }
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
            Section("Site and ports") {
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
            if bench.needsService {
                Section {
                    Label("This bench has no BenchBar agent yet. Run \(BenchText.command("adopt", bench: bench.path)) in Terminal.",
                          systemImage: "wrench.and.screwdriver")
                        .foregroundStyle(.orange).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
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
                        }
                        Spacer()
                        if !row.isDefault {
                            Button("Make Default") { Task { await workbench.setDefaultSite(row.name, on: bench) } }
                                .disabled(busy)
                        }
                        Button("Open") { Workspace.open(row.url) }
                    }
                }
            } header: {
                HStack {
                    Text("Sites")
                    Spacer()
                    Button { addingSite = true } label: { Label("Add Site…", systemImage: "plus") }
                        .disabled(busy)
                }
            } footer: {
                Text("The default site is the one benchup waits for, the runner pings and ⌘O opens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let fix = SiteRow.hostsFix(rows, bench: bench.path) {
                Section("Hosts") {
                    Text("A site without a 127.0.0.1 line in /etc/hosts does not open by its name. Adding it needs your password, so run this in Terminal:")
                        .font(.callout)
                    HStack {
                        Text(fix).font(.callout.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("Copy") { Workspace.copy(fix) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $addingSite) {
            AddSiteSheet(bench: bench) { name, password in
                addingSite = false
                Task { await workbench.addSite(name, adminPassword: password, on: bench) }
            } cancel: { addingSite = false }
        }
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
