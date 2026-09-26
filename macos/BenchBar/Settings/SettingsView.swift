import SwiftUI
import UniformTypeIdentifiers

/// The General and Menu Bar panes of the BenchBar window (the settings
/// that belong to the app itself; per bench settings live on each bench's page).
struct SettingsView: View {
    enum Part { case general, menuBar }

    @Bindable var settings: AppSettings
    let store: BenchStore
    let library: RunnerLibrary
    let launchAtLogin: LaunchAtLogin
    let notifier: Notifier
    var part: Part = .general
    let chooseCLI: () -> Void

    @State private var previewState: BenchState = .running
    @State private var cliPathDraft = ""
    @State private var importMessage: String?

    init(settings: AppSettings, store: BenchStore, library: RunnerLibrary, launchAtLogin: LaunchAtLogin,
         notifier: Notifier, part: Part = .general, chooseCLI: @escaping () -> Void) {
        self.settings = settings
        self.store = store
        self.library = library
        self.launchAtLogin = launchAtLogin
        self.notifier = notifier
        self.part = part
        self.chooseCLI = chooseCLI
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch part {
            case .general:
                PaneHeader(symbol: "gearshape.fill", tint: .gray, title: "General",
                           subtitle: "Startup, notifications and the benchbar command BenchBar runs.")
            case .menuBar:
                PaneHeader(symbol: "menubar.rectangle", tint: .blue, title: "Menu Bar",
                           subtitle: "The runner in the menu bar shows your bench's state at a glance.")
            }
            Form {
                switch part {
                case .general:
                    startupSection
                    notificationsSection
                    cliSection
                    shortcutsSection
                case .menuBar:
                    previewSection
                    runnerSection
                    motionSection
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            cliPathDraft = settings.cliPath
            library.reload()
            launchAtLogin.refresh()
            Task { await notifier.refresh() }
        }
    }

    // MARK: menu bar

    private var previewSection: some View {
        Section {
            VStack(spacing: 14) {
                RunnerPreview(runner: library.runner(settings.runnerID), state: previewState)
                    .frame(height: Runner.pointHeight * 3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Picker("Preview", selection: $previewState) {
                    Text("Stopped").tag(BenchState.stopped)
                    Text("Starting").tag(BenchState.starting)
                    Text("Running").tag(BenchState.running)
                    Text("Crashed").tag(BenchState.crashed)
                    Text("Unknown").tag(BenchState.unknown)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Pick a state to see how the runner shows it.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var runnerSection: some View {
        Section {
            Picker("Runner", selection: $settings.runnerID) {
                ForEach(library.all) { runner in
                    Text(library.isCustom(runner.id) && !runner.author.isEmpty ? "\(runner.name) (by \(runner.author))" : runner.name)
                        .tag(runner.id)
                }
            }
            LabeledContent("Your runners") {
                HStack {
                    if library.isCustom(settings.runnerID) {
                        Button("Remove", role: .destructive) {
                            let id = settings.runnerID
                            settings.runnerID = Runner.defaultID
                            library.remove(id)
                        }
                    }
                    Button("Show Folder") { library.revealFolder() }
                    Button("Import…", action: importRunner)
                }
            }
            if let importMessage {
                Text(importMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ForEach(library.problems) { problem in
                Label("\(problem.id): \(problem.message)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        } header: {
            Text("Runner")
        } footer: {
            Text("A runner is a folder of frames with a manifest.json, or a .zip of one; docs/runners.md shows how to draw your own.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var motionSection: some View {
        Section {
            Toggle(isOn: $settings.speedEnabled) {
                Text("Run faster when the bench is busy")
                Text("Speed follows the CPU use of the bench's processes, sampled every 2 seconds.")
            }
        } header: {
            Text("Motion")
        } footer: {
            Text("With Reduce Motion on in System Settings, the runner shows a still pose.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: shortcuts

    private var shortcutsSection: some View {
        Section {
            ForEach(Self.shortcuts, id: \.keys) { item in
                LabeledContent(item.action) {
                    Text(item.keys).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Keyboard shortcuts")
        } footer: {
            Text("In the menu bar popover, for the bench it shows.").font(.caption).foregroundStyle(.secondary)
        }
    }

    static let shortcuts: [(action: String, keys: String)] = [
        ("Start, stop, restart", "⌘U  ⌘D  ⌘R"),
        ("Open the site", "⌘O"),
        ("Logs", "⌘L"),
        ("Show in Finder", "⌘F"),
        ("Run doctor", "⌘K"),
        ("Apps, sites and settings", "⌘M"),
    ]

    // MARK: general

    private var startupSection: some View {
        Section {
            Toggle("Open BenchBar at login", isOn: Binding(
                get: { launchAtLogin.isOn },
                set: { launchAtLogin.setEnabled($0) }
            ))
            switch launchAtLogin.status {
            case .requiresApproval:
                LabeledContent {
                    Button("Open Login Items…") { launchAtLogin.openSystemSettings() }
                } label: {
                    Label("macOS needs your approval in Login Items.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            case .notFound:
                Text("macOS cannot register this copy. Install BenchBar in Applications (scripts/macos-install-local.sh) and try again.")
                    .font(.caption).foregroundStyle(.secondary)
            case .enabled, .disabled:
                EmptyView()
            }
            if let error = launchAtLogin.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Startup")
        } footer: {
            Text("Your benches run as their own login agents, so they keep running when BenchBar is closed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle(isOn: $settings.notificationsEnabled) {
                Text("Notify me when a bench crashes or recovers")
                Text("One notification when it goes down, one when it is back.")
            }
            .onChange(of: settings.notificationsEnabled) { _, on in
                if on && notifier.permission == .notAsked {
                    Task { await notifier.requestPermission() }
                }
            }
            if settings.notificationsEnabled && notifier.permission == .denied {
                LabeledContent {
                    Button("Open Notifications…") { notifier.openSystemSettings() }
                } label: {
                    Label("Notifications for BenchBar are off in System Settings.", systemImage: "bell.slash.fill")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Notifications")
        }
    }

    // MARK: CLI

    private var cliSection: some View {
        Section {
            LabeledContent("Status") { cliStatus }
            LabeledContent("Location") {
                HStack {
                    TextField("Location", text: $cliPathDraft, prompt: Text("Automatic"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                        .onSubmit(applyCLIPath)
                    Button("Choose…", action: chooseCLI)
                }
            }
            if case .ready(let url) = store.cli {
                LabeledContent("") {
                    HStack {
                        if !settings.cliPath.isEmpty {
                            Button("Use Automatic") {
                                cliPathDraft = ""
                                applyCLIPath()
                            }
                        }
                        Button("Copy Path") { Workspace.copy(url.path) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("Command line tool")
        } footer: {
            Text("Automatic looks in ~/.local/bin (linked by benchbar repair), then Homebrew. Every change the app makes runs this command, the same one you use in Terminal.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: settings.cliPath) { _, path in cliPathDraft = path }
    }

    @ViewBuilder private var cliStatus: some View {
        switch store.cli {
        case .ready(let url):
            Label(url.path, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).textSelection(.enabled)
        case .missing(let error):
            Label(error.localizedDescription, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .searching:
            ProgressView().controlSize(.small)
        }
    }

    /// A runner folder or a .zip of one, from the file picker.
    private func importRunner() {
        let panel = NSOpenPanel()
        panel.title = "Import a runner"
        panel.message = "Choose a runner folder (with manifest.json) or a .zip of one. See docs/runners.md."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do throws(RunnerError) {
            let id = try library.importRunner(from: url)
            settings.runnerID = id
            importMessage = "Imported \(library.runner(id).name)."
        } catch {
            importMessage = "Not imported: \(error.localizedDescription)"
        }
    }

    private func applyCLIPath() {
        let path = cliPathDraft.trimmingCharacters(in: .whitespaces)
        Task { await store.useCLI(path: path) }
    }
}
