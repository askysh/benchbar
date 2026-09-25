import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let store: BenchStore
    let library: RunnerLibrary
    let launchAtLogin: LaunchAtLogin
    let notifier: Notifier
    let chooseCLI: () -> Void

    @State private var previewState: BenchState = .running
    @State private var cliPathDraft = ""
    @State private var importMessage: String?
    /// A scheduler change waiting for its confirmation: the bench and the new value.
    @State private var schedulerChange: (path: String, on: Bool)?

    var body: some View {
        Form {
            runnerSection
            generalSection
            benchesSection
            cliSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            cliPathDraft = settings.cliPath
            library.reload()
            launchAtLogin.refresh()
            Task { await notifier.refresh() }
        }
    }

    // MARK: benches

    /// Per bench settings that live in the CLI (it stores them per bench):
    /// the scheduler. Changing it runs benchbar service after a confirmation.
    @ViewBuilder private var benchesSection: some View {
        if !store.benches.isEmpty {
            Section {
                ForEach(store.benches) { bench in
                    Toggle(isOn: Binding(
                        get: { bench.schedulerOn ?? false },
                        set: { schedulerChange = (bench.path, $0) }
                    )) {
                        Text("Scheduler for \(bench.name)")
                        Text(bench.schedulerOn == nil ? "Needs benchbar 0.4 or later" : "Runs scheduled jobs (bench schedule) in the background")
                    }
                    .disabled(bench.schedulerOn == nil || bench.pending != nil)
                }
            } header: {
                Text("Benches")
            }
            .alert(schedulerAlertTitle, isPresented: Binding(
                get: { schedulerChange != nil },
                set: { if !$0 { schedulerChange = nil } }
            )) {
                Button(schedulerChange?.on == true ? "Turn On and Restart" : "Turn Off and Restart") {
                    guard let change = schedulerChange,
                          let bench = store.benches.first(where: { $0.path == change.path }) else { return }
                    schedulerChange = nil
                    Task { await store.setScheduler(change.on, on: bench) }
                }
                Button("Cancel", role: .cancel) { schedulerChange = nil }
            } message: {
                Text("BenchBar runs benchbar service \(schedulerChange?.on == true ? "--with-schedule" : "--without-schedule"), then restarts the bench if it is running.")
            }
        }
    }

    private var schedulerAlertTitle: String {
        guard let change = schedulerChange,
              let bench = store.benches.first(where: { $0.path == change.path }) else { return "Scheduler" }
        return change.on ? "Run the scheduler for \(bench.name)?" : "Stop the scheduler for \(bench.name)?"
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
