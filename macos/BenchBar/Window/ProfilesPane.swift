import SwiftUI

/// Built in and team profiles. A team profile is a file on this Mac (or in a
/// team's config repository), never part of BenchBar; one is created from an
/// existing bench, read only.
struct ProfilesPane: View {
    let store: BenchStore
    let workbench: Workbench
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(symbol: "person.2.fill", tint: .indigo, title: "Team Profiles",
                       subtitle: "Pin a base profile and your team's apps, then set up a bench from it.") {
                Button { creating = true } label: { Label("Create from Bench…", systemImage: "plus") }
                    .primaryAction()
                    .disabled(store.benches.isEmpty)
            }
            ChangeResultBanner(workbench: workbench, scope: Workbench.profilesScope)
                .padding(.horizontal, 20).padding(.top, 6)
            profiles
        }
        .task { await workbench.loadProfiles() }
        .sheet(isPresented: $creating) {
            CreateProfileSheet(benches: store.benches) { name, bench in
                creating = false
                Task { await workbench.createProfile(name, from: bench) }
            } cancel: { creating = false }
        }
    }

    private var profiles: some View {
        Form {
            Section {
                ForEach(workbench.profiles) { profile in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: profile.isTeam ? "person.2.fill" : "shippingbox")
                            .foregroundStyle(profile.valid ? Color.accentColor : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(profile.name).font(.body.weight(.medium))
                                if let base = profile.base { Tag(text: "based on \(base)", color: .secondary) }
                            }
                            if let label = profile.label { Text(label).font(.caption).foregroundStyle(.secondary) }
                            if let error = profile.error { Text(error).font(.caption).foregroundStyle(.red) }
                            if profile.isTeam {
                                Text(profile.file).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        Spacer()
                        if profile.isTeam {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: profile.file)])
                            }
                            .controlSize(.small)
                        }
                    }
                }
                if let error = workbench.profilesError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Set up a bench from one with benchbar install --profile NAME. Team profiles are files in ~/.config/benchbar/profiles or a folder in BENCHBAR_PROFILE_PATH (a team repository works well), never inside BenchBar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
            Text("BenchBar reads the bench (its apps, their repositories and branches, and its Frappe version) and writes ~/.config/benchbar/profiles/NAME.toml. The bench is not changed; no site data or password goes into the file.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Create") {
                    if let bench = benches.first(where: { $0.path == benchPath }) { create(name, bench) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!SiteName.isValid(name) || benchPath.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { benchPath = benches.first?.path ?? "" }
    }
}

struct AboutPane: View {
    let store: BenchStore

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("BenchBar").font(.title.weight(.semibold))
                    Text("Version \(appVersion)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Frappe benches on your Mac, from the menu bar.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                LabeledContent("BenchBar", value: appVersion)
                if case .ready(let url) = store.cli {
                    LabeledContent("Command line tool", value: url.path)
                }
                Link("github.com/askysh/benchbar", destination: URL(string: "https://github.com/askysh/benchbar")!)
            }
            Section {
                Text("benchbar mcp lets Claude Code, Cursor and other agents list your benches, read status, doctor and logs, and start, stop or restart them. Add it once:")
                    .font(.callout)
                HStack {
                    Text(MCPSnippet.claude).font(.callout.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("Copy") { Workspace.copy(MCPSnippet.claude) }
                }
            } header: {
                Text("For coding agents")
            }
            Section {
                Text("Frappe and ERPNext are trademarks of Frappe Technologies; BenchBar is not affiliated with or endorsed by them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

nonisolated enum MCPSnippet {
    static let claude = "claude mcp add benchbar -- benchbar mcp"
}
