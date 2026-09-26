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
        Form {
            switch part {
            case .general:
                generalSection
                cliSection
            case .menuBar:
                runnerSection
            }
        }
        .formStyle(.grouped)
        .onAppear {
            cliPathDraft = settings.cliPath
            library.reload()
            launchAtLogin.refresh()
            Task { await notifier.refresh() }
        }
    }

    // MARK: runner

    private var runnerSection: some View {
        Section("Menu bar runner") {
            Picker("Runner", selection: $settings.runnerID) {
                ForEach(library.all) { runner in
                    Text(library.isCustom(runner.id) && !runner.author.isEmpty ? "\(runner.name) (by \(runner.author))" : runner.name)
                        .tag(runner.id)
                }
            }
            HStack {
                Spacer()
                RunnerPreview(runner: library.runner(settings.runnerID), state: previewState)
                    .frame(height: Runner.pointHeight * 2)
                Spacer()
            }
            .padding(.vertical, 6)
            Picker("Preview", selection: $previewState) {
                Text("Stopped").tag(BenchState.stopped)
                Text("Starting").tag(BenchState.starting)
                Text("Running").tag(BenchState.running)
                Text("Crashed").tag(BenchState.crashed)
                Text("Unknown").tag(BenchState.unknown)
            }
            .pickerStyle(.segmented)
            HStack {
                Button("Import Runner…", action: importRunner)
                Button("Show Runners Folder") { library.revealFolder() }
                Spacer()
                if library.isCustom(settings.runnerID) {
                    Button("Remove") {
                        let id = settings.runnerID
                        settings.runnerID = Runner.defaultID
                        library.remove(id)
                    }
                }
            }
            .controlSize(.small)
            if let importMessage {
                Text(importMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ForEach(library.problems) { problem in
                Label("\(problem.id): \(problem.message)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Toggle("Run faster when the bench is busy", isOn: $settings.speedEnabled)
            Text("Speed follows the CPU use of the bench's processes, sampled every 2 seconds. With Reduce Motion on, the runner shows a still pose.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: general

    private var generalSection: some View {
        Section("General") {
            Toggle("Open BenchBar at login", isOn: Binding(
                get: { launchAtLogin.isOn },
                set: { launchAtLogin.setEnabled($0) }
            ))
            switch launchAtLogin.status {
            case .requiresApproval:
                HStack {
                    Text("macOS needs your approval in Login Items.")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Open Login Items…") { launchAtLogin.openSystemSettings() }
                        .controlSize(.small)
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
            Toggle("Notify me when a bench crashes or recovers", isOn: $settings.notificationsEnabled)
                .onChange(of: settings.notificationsEnabled) { _, on in
                    if on && notifier.permission == .notAsked {
                        Task { await notifier.requestPermission() }
                    }
                }
            if settings.notificationsEnabled && notifier.permission == .denied {
                HStack {
                    Text("Notifications for BenchBar are off in System Settings.")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Open Notifications…") { notifier.openSystemSettings() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: CLI

    private var cliSection: some View {
        Section("Command line tool") {
            HStack {
                TextField("benchbar path", text: $cliPathDraft, prompt: Text("Automatic"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyCLIPath)
                Button("Choose…", action: chooseCLI)
            }
            HStack {
                cliStatus
                Spacer()
                if !settings.cliPath.isEmpty {
                    Button("Use Automatic") {
                        cliPathDraft = ""
                        applyCLIPath()
                    }
                    .controlSize(.small)
                }
            }
        }
        .onChange(of: settings.cliPath) { _, path in cliPathDraft = path }
    }

    @ViewBuilder private var cliStatus: some View {
        switch store.cli {
        case .ready(let url):
            Label("Using \(url.path)", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green).textSelection(.enabled)
        case .missing(let error):
            Label(error.localizedDescription, systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.red)
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
