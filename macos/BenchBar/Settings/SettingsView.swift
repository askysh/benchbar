import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let store: BenchStore
    let launchAtLogin: LaunchAtLogin
    let notifier: Notifier
    let chooseCLI: () -> Void

    @State private var previewState: BenchState = .running
    @State private var cliPathDraft = ""

    var body: some View {
        Form {
            runnerSection
            generalSection
            cliSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            cliPathDraft = settings.cliPath
            launchAtLogin.refresh()
            Task { await notifier.refresh() }
        }
    }

    // MARK: runner

    private var runnerSection: some View {
        Section("Menu bar runner") {
            Picker("Runner", selection: $settings.runnerID) {
                ForEach(Runner.builtIns) { runner in
                    Text(runner.name).tag(runner.id)
                }
            }
            HStack {
                Spacer()
                RunnerPreview(runner: Runner.builtIn(settings.runnerID), state: previewState)
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

    private func applyCLIPath() {
        let path = cliPathDraft.trimmingCharacters(in: .whitespaces)
        Task { await store.useCLI(path: path) }
    }
}
