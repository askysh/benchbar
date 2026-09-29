import SwiftUI
import UniformTypeIdentifiers

/// Built in and team profiles. A team profile is a file on this Mac (or in a
/// team's config repository), never part of BenchBar; one is created from an
/// existing bench, read only, imported from a file or link, or comes from a
/// subscribed repository. Nothing on this page installs an app.
struct ProfilesPane: View {
    let store: BenchStore
    let workbench: Workbench
    let router: WindowRouter
    @State private var sheet: ProfileSheet?
    @State private var removing: ProfileInfo?
    @State private var dropTargeted = false

    /// One sheet at a time; each carries its own run.
    enum ProfileSheet: Identifiable {
        case create
        case importing(ProfileImportRun, autoReview: Bool)
        case subscribe(ProfileSubscribeRun)
        case export(ProfileExportRun)
        case update(ProfileUpdateRun)
        case check(ProfileCheckRun)

        var id: String {
            switch self {
            case .create: return "create"
            case .importing: return "import"
            case .subscribe: return "subscribe"
            case .export(let run): return "export-\(run.name)"
            case .update(let run): return "update-\(run.name)"
            case .check(let run): return "check-\(run.name)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(symbol: "person.2.fill", tint: .indigo, title: "Team Profiles",
                       subtitle: "Pin a base profile and your team's apps, then set up a bench from it.") {
                HStack(spacing: 8) {
                    Button { sheet = .importing(ProfileImportRun(workbench: workbench), autoReview: false) } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                    Button { sheet = .subscribe(ProfileSubscribeRun(workbench: workbench)) } label: {
                        Label("Subscribe…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button { sheet = .create } label: { Label("Create from Bench…", systemImage: "plus") }
                        .primaryAction()
                        .disabled(store.benches.isEmpty)
                }
            }
            ChangeResultBanner(workbench: workbench, scope: Workbench.profilesScope)
                .padding(.horizontal, 20).padding(.top, 6)
            profiles
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3).padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let file = urls.first(where: { $0.isFileURL && $0.pathExtension.lowercased() == "toml" }) else { return false }
            sheet = .importing(ProfileImportRun(source: file.path, workbench: workbench), autoReview: true)
            return true
        } isTargeted: { dropTargeted = $0 }
        .task { await workbench.loadProfiles() }
        .onAppear(perform: takeRequest)
        .onChange(of: router.profileRequest) { takeRequest() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .create:
                CreateProfileSheet(benches: store.benches) { name, bench in
                    self.sheet = nil
                    Task { await workbench.createProfile(name, from: bench) }
                } cancel: { self.sheet = nil }
            case .importing(let run, let autoReview):
                ImportProfileSheet(run: run, autoReview: autoReview) { self.sheet = nil }
            case .subscribe(let run):
                SubscribeProfilesSheet(run: run) { self.sheet = nil }
            case .export(let run):
                ExportProfileSheet(run: run) { self.sheet = nil }
            case .update(let run):
                UpdateProfileSheet(run: run) { self.sheet = nil }
            case .check(let run):
                CheckAccessSheet(run: run) { self.sheet = nil }
            }
        }
        .confirmationDialog(removeTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { profile in
            Button("Remove", role: .destructive) { Task { await workbench.removeProfile(profile.name) } }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text(removeMessage(profile))
        }
    }

    /// A benchbar://profile link opened the window: prefill, never act.
    private func takeRequest() {
        guard let request = router.profileRequest else { return }
        router.profileRequest = nil
        switch request {
        case .importProfile(let url):
            sheet = .importing(ProfileImportRun(source: url, workbench: workbench), autoReview: false)
        case .subscribe(let url):
            sheet = .subscribe(ProfileSubscribeRun(repo: url, workbench: workbench))
        }
    }

    private var removeTitle: String {
        guard let removing else { return "Remove profile?" }
        return removing.origin == .subscribed ? "Remove the subscription?" : "Remove \(removing.name)?"
    }

    private func removeMessage(_ profile: ProfileInfo) -> String {
        if profile.origin == .subscribed {
            let repo = profile.subscription.map { ProfileInfo.shortRepo($0.repo) } ?? "its repository"
            let siblings = workbench.profiles.filter { $0.subscription?.dir == profile.subscription?.dir && $0.origin == .subscribed }.map(\.name)
            return "This removes the subscription to \(repo) with all its profiles (\(siblings.joined(separator: ", "))). The folder is moved to ~/.config/benchbar/removed, not deleted. Benches set up from them are not changed."
        }
        return "The file is moved to ~/.config/benchbar/removed, not deleted. Benches set up from it are not changed."
    }

    private var profiles: some View {
        Form {
            Section {
                ForEach(workbench.profiles) { profile in row(profile) }
                if let error = workbench.profilesError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Set up a bench from one with benchbar install --profile NAME. Team profiles are files in ~/.config/benchbar/profiles, a subscribed repository or a folder in BENCHBAR_PROFILE_PATH, never inside BenchBar. Drop a .toml file here to import it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ profile: ProfileInfo) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: profile.isTeam ? "person.2.fill" : "shippingbox")
                .foregroundStyle(profile.valid ? Color.accentColor : .red)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.body.weight(.medium))
                    Tag(text: profile.originText, color: profile.origin == .subscribed ? .indigo : .secondary)
                    if let base = profile.base { Tag(text: "based on \(base)", color: .secondary) }
                    if let outdated = profile.subscription?.outdatedText { Tag(text: outdated, color: .orange) }
                }
                if let label = profile.label { Text(label).font(.caption).foregroundStyle(.secondary) }
                if let error = profile.error { Text(error).font(.caption).foregroundStyle(.red) }
                if let winner = profile.shadowedBy {
                    Label("Not used: \(winner) has the same name and comes first", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if profile.isTeam {
                    Text(profile.sourceURL ?? profile.file).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Spacer()
            if profile.isTeam { menu(profile) }
        }
    }

    private func menu(_ profile: ProfileInfo) -> some View {
        Menu {
            Button("Export…") { sheet = .export(ProfileExportRun(name: profile.name, workbench: workbench)) }
                .disabled(!profile.canExport)
            if profile.canUpdate {
                Button("Update…") { sheet = .update(ProfileUpdateRun(name: profile.name, workbench: workbench)) }
            }
            Button("Check Access") { sheet = .check(ProfileCheckRun(name: profile.name, workbench: workbench)) }
                .disabled(!profile.canCheck)
            Button("Show in Finder") { Workspace.reveal([profile.file]) }
            if profile.canRemove {
                Divider()
                Button(profile.origin == .subscribed ? "Remove Subscription…" : "Remove…", role: .destructive) { removing = profile }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Export, update, check or remove \(profile.name)")
    }
}

struct CreateProfileSheet: View {
    let benches: [BenchModel]
    let create: (String, BenchModel) -> Void
    let cancel: () -> Void
    @State private var name = ""
    @State private var benchPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create a team profile").font(.headline)
            Form {
                TextField("Profile name", text: $name, prompt: Text("acme"))
                Picker("From bench", selection: $benchPath) {
                    ForEach(benches) { Text($0.name).tag($0.path) }
                }
            }
            .formStyle(.grouped)
            if !name.isEmpty && !ProfileName.isValid(name) {
                Text("Lower case letters, digits, '.', '_' or '-', starting with a letter or digit.")
                    .font(.caption).foregroundStyle(.red)
            }
            Text("BenchBar reads the bench (its apps, their repositories and branches, and its Frappe version) and writes ~/.config/benchbar/profiles/NAME.toml. The bench is not changed; no site data or password goes into the file.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Create") {
                    if let bench = benches.first(where: { $0.path == benchPath }) { create(name, bench) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ProfileName.isValid(name) || benchPath.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { benchPath = benches.first?.path ?? "" }
    }
}
