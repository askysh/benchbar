import SwiftUI

/// The apps of one bench: what is cloned, on which branch, on which sites,
/// and the three changes the CLI offers (add, install on a site, update).
struct BenchApps: View {
    let store: BenchStore
    let workbench: Workbench
    let bench: BenchModel
    @State private var adding = false
    @State private var updating: AppInfo?

    private var busy: Bool {
        bench.pending != nil || bench.isChangingScheduler || bench.activity != nil || store.waitsForOtherBench(bench)
    }
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
                HStack {
                    Text("Apps")
                    Spacer()
                    Button { Task { await workbench.loadApps(bench, liveSites: true) } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Ask bench which sites have which app (needs MariaDB)")
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
        .task(id: bench.path) { await workbench.loadApps(bench) }
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
                }
                Text([app.branch.map { "branch \($0)" } ?? "detached", app.repo].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text(app.sites.isEmpty ? "on no site yet" : "on \(app.sites.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            let missing = AppSource.sitesWithout(app, among: siteNames)
            if !missing.isEmpty && app.name != "frappe" {
                Menu("Install") {
                    ForEach(missing, id: \.self) { site in
                        Button("On \(site)") { Task { await workbench.installApp(app.name, site: site, on: bench) } }
                    }
                }
                .fixedSize()
                .disabled(busy)
            }
            Button("Update…") { updating = app }
                .disabled(busy || app.branch == nil || app.dirty)
                .help(app.dirty ? "The app has local changes; commit or stash them first" : "Shows the changelog before anything changes")
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an app to \(bench.name)").font(.headline)
            Form {
                TextField("App or repository", text: $source, prompt: Text("erpnext, or https://github.com/org/app"))
                TextField("Branch", text: $branch, prompt: Text(AppSource.isURL(source) ? "the repository's default" : "the profile's branch"))
                Picker("Install on", selection: $site) {
                    Text("No site yet").tag("")
                    ForEach(sites, id: \.self) { Text($0).tag($0) }
                }
            }
            .formStyle(.grouped)
            Text(AppSource.isURL(source)
                 ? "Private repositories work when your SSH key (or a git credential helper) can read them; BenchBar checks access first, so a missing key fails in seconds."
                 : "A name from the app registry gets the branch that matches this bench's profile.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("benchbar app add runs bench get-app, installs the app's requirements and builds its assets. This can take several minutes; the bench keeps running.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Add App") { add(source, branch, site.isEmpty ? nil : site) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update \(app.name)").font(.headline)
            if let plan {
                if plan.isUpToDate {
                    Label("\(app.name) is up to date on \(plan.branch ?? "its branch").", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("\(plan.commitsTotal) new commit\(plan.commitsTotal == 1 ? "" : "s") on \(plan.branch ?? "the branch"):")
                        .font(.callout)
                    List(plan.commits) { commit in
                        HStack(alignment: .firstTextBaseline) {
                            Text(commit.sha).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(commit.subject).font(.callout)
                        }
                    }
                    .frame(height: 170)
                    Text("Then, in order:").font(.callout)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(plan.steps) { step in
                            Label(step.name, systemImage: "circle").font(.callout)
                        }
                    }
                    if !plan.sites.isEmpty {
                        Text("Each site is backed up before it is migrated: \(plan.sites.joined(separator: ", ")).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Fetching the changes…").foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                if let plan, !plan.isUpToDate {
                    Button("Update") {
                        close()
                        Task { await workbench.updateApp(app.name, on: bench) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            switch await workbench.updatePlan(app.name, on: bench) {
            case .success(let p): plan = p
            case .failure(let e): error = e.message
            }
        }
    }
}
