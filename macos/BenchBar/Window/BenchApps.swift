import SwiftUI

/// The apps of one bench: what is cloned, on which branch, on which sites,
/// and the three changes the CLI offers (add, install on a site, update).
struct BenchApps: View {
    let store: BenchStore
    let workbench: Workbench
    let bench: BenchModel
    @State private var adding = false
    @State private var updating: AppInfo?

    private var busy: Bool { !store.canChange(bench) }
    private var siteNames: [String] { bench.siteRows.map(\.name) }

    var body: some View {
        let list = workbench.apps[bench.path]
        Form {
            Section {
                if let list {
                    ForEach(list.apps) { app in row(app) }
                    if list.apps.isEmpty { Text("No apps").foregroundStyle(.secondary) }
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
                    MoreMenu(help: "Refresh the site lists or check the remotes") {
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
            AddAppSheet(bench: bench, sites: siteNames) { source, branch, site in
                adding = false
                Task { await workbench.addApp(source, branch: branch, site: site, on: bench) }
            } cancel: { adding = false }
        }
        .sheet(item: $updating) { app in
            UpdateAppSheet(workbench: workbench, bench: bench, app: app) { updating = nil }
        }
    }

    private func row(_ app: AppInfo) -> some View {
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
                Text(app.sites.isEmpty ? "on no site yet" : "on \(app.sites.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Update…") { updating = app }
                .disabled(busy || app.branch == nil || app.dirty)
                .help(app.dirty ? "The app has local changes; commit or stash them first" : "Shows the changelog before anything changes")
            AppMenu(app: app, missingSites: app.name == "frappe" ? [] : AppSource.sitesWithout(app, among: siteNames), busy: busy) { site in
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

struct AddAppSheet: View {
    let bench: BenchModel
    let sites: [String]
    let add: (String, String, String?) -> Void
    let cancel: () -> Void
    @State private var source = ""
    @State private var branch = ""
    @State private var site = ""

    var body: some View {
        SheetScaffold("Add an App to \(bench.name)",
                      explanation: "Clones an app from the app registry or a git repository and installs it.") {
            Form {
                TextField("App or repository", text: $source, prompt: Text("erpnext, or https://github.com/org/app"))
                TextField("Branch", text: $branch, prompt: Text(AppSource.isURL(source) ? "the repository's default" : "the profile's branch"))
                Picker("Install on", selection: $site) {
                    Text("No site yet").tag("")
                    ForEach(sites, id: \.self) { Text($0).tag($0) }
                }
            }
            .formStyle(.columns)
            SheetNote(AppSource.isURL(source)
                      ? "Private repositories work when your SSH key (or a git credential helper) can read them; BenchBar checks access first, so a missing key fails in seconds."
                      : "A name from the app registry gets the branch that matches this bench's profile.")
            SheetNote("benchbar app add runs bench get-app, installs the app's requirements and builds its assets. This can take several minutes; the bench keeps running.")
        } actions: {
            CancelButton(action: cancel)
            Button("Add App") { add(source, branch, site.isEmpty ? nil : site) }
                .keyboardShortcut(.defaultAction)
                .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

/// The changelog first (app update --dry-run --json), then the update.
struct UpdateAppSheet: View {
    let workbench: Workbench
    let bench: BenchModel
    let app: AppInfo
    let close: () -> Void
    @State private var plan: AppUpdatePlan?
    @State private var error: String?

    private var phase: SheetPhase {
        if let error { return .failed(error, title: "No changelog for \(app.name)") }
        guard let plan else { return .loading("Fetching the changes…") }
        return plan.isUpToDate ? .done(.success("\(app.name) is up to date on \(plan.branch ?? "its branch").")) : .ready
    }

    var body: some View {
        SheetScaffold("Update \(app.name)",
                      explanation: "Shows the new commits and the steps before anything changes.",
                      phase: phase) {
            if let plan, !plan.isUpToDate {
                Text("\(plan.commitsTotal) new commit\(plan.commitsTotal == 1 ? "" : "s") on \(plan.branch ?? "the branch"):")
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
                if !plan.sites.isEmpty {
                    SheetNote("Each site is backed up before it is migrated: \(plan.sites.joined(separator: ", ")).")
                }
            }
        } actions: {
            if let plan, !plan.isUpToDate {
                CancelButton(action: close)
                Button("Update") {
                    close()
                    Task { await workbench.updateApp(app.name, on: bench) }
                }
                .keyboardShortcut(.defaultAction)
            } else if plan == nil && error == nil {
                CancelButton(action: close)
            } else {
                DoneButton(action: close)
            }
        }
        .task {
            switch await workbench.updatePlan(app.name, on: bench) {
            case .success(let p): plan = p
            case .failure(let e): error = e.message
            }
        }
    }
}
