import SwiftUI

// 5 Install and 6 Done.

struct InstallPage: View {
    let run: WizardRun
    @State private var rootPassword = ""
    @State private var revealRootPassword = false

    var body: some View {
        let state = run.state
        WizardScaffold("Installing \(state.form.site)", explanation: explanation(state), phase: phase(state)) {
            outcome(state)
            steps(state)
            output
        } leading: {
            if case .failed(let failure) = state.installPhase {
                Button("Copy") { Workspace.copy(Self.copyText(failure)) }
                    .help("Copy the failed step, its message and the fix")
                if let log = failure.log ?? state.progress.log {
                    Button("Open Log") { Workspace.openFile(log) }
                }
            }
        } actions: {
            if state.isInstalling {
                Button("Stop") { run.send(.stop) }
                    .disabled(state.stopRequested)
                    .help("Stops the install; steps already done stay done")
            } else {
                WizardBackButton(run: run)
                WizardPrimaryButton(run: run, also: run.canStartChange)
            }
        }
    }

    private func explanation(_ state: WizardState) -> String {
        switch state.installPhase {
        case .running: "This takes a while: Homebrew packages, the bench, the apps and the site. You can use other apps meanwhile."
        case .failed: "The install stopped. Retry picks up where it stopped: every step checks what is already done."
        case .needsRootPassword: "MariaDB already has a root password that BenchBar does not know."
        case .stopped: "You stopped the install."
        case .idle, .succeeded: ""
        }
    }

    private func phase(_ state: WizardState) -> SheetPhase {
        guard state.installPhase == .running else { return .ready }
        if state.stopRequested { return .running("Stopping…") }
        return .running(state.progress.running.map { "\($0.name)…" } ?? "Starting…")
    }

    @ViewBuilder private func outcome(_ state: WizardState) -> some View {
        switch state.installPhase {
        case .failed(let failure):
            SheetOutcome(symbol: "exclamationmark.triangle.fill", tint: .red,
                         title: failure.step.map { "\($0) failed" } ?? "The install failed",
                         detail: [failure.message, failure.fix].compactMap { $0 }.joined(separator: "\n\n"),
                         monospaced: false)
        case .needsRootPassword(let fix):
            SheetOutcome(symbol: "lock.trianglebadge.exclamationmark.fill", tint: .orange, title: "Needs the MariaDB root password",
                         detail: fix)
            VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
                HStack(spacing: WindowMetrics.rowSpacing) {
                    PasswordField(text: Binding(get: { rootPassword }, set: { rootPassword = $0; run.send(.setRootPassword($0)) }),
                                  reveal: revealRootPassword)
                        .frame(maxWidth: 280)
                    Toggle(isOn: $revealRootPassword) { Image(systemName: revealRootPassword ? "eye.slash" : "eye") }
                        .toggleStyle(.button)
                        .accessibilityLabel(revealRootPassword ? "Hide the password" : "Show the password")
                }
                SheetNote("It goes to the retried benchbar process only, never on a command line or to disk.")
            }
        case .stopped:
            SheetOutcome(symbol: "stop.circle.fill", tint: .orange, title: "Stopped",
                         detail: "Steps that finished stay done and the step that was running may be half done. Run the wizard again to finish it, or run benchbar repair in Terminal.")
        case .idle, .running, .succeeded:
            EmptyView()
        }
    }

    private func steps(_ state: WizardState) -> some View {
        let progress = state.progress
        return VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
            ForEach(progress.topLevel, id: \.key) { row in
                InstallStepRow(row: row, progress: progress.progress(for: row), depth: 0)
                ForEach(progress.children(of: row.id), id: \.key) { child in
                    InstallStepRow(row: child, progress: progress.progress(for: child), depth: 1)
                }
            }
        }
    }

    private var output: some View {
        DisclosureGroup("Command output") {
            ScrollView {
                Text(run.logLines.isEmpty ? "Nothing yet." : run.logLines.joined(separator: "\n"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .frame(height: 160)
        }
    }

    static func copyText(_ failure: WizardState.Failure) -> String {
        [failure.step.map { "\($0) failed" }, failure.message, failure.fix].compactMap { $0 }.joined(separator: "\n")
    }
}

struct InstallStepRow: View {
    let row: InstallProgress.Row
    let progress: InstallProgressLine?
    let depth: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
            glyph.frame(width: 16)
            VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing) {
                HStack(spacing: 6) {
                    Text(row.name).font(depth == 0 ? .body : .callout)
                        .foregroundStyle(row.status == nil ? .secondary : .primary)
                    if row.sudo, row.status == nil || row.status == .running {
                        Tag(text: "Asks for your password", color: .orange)
                    }
                    if row.alreadyDone { Tag(text: "Already done", color: .secondary) }
                    Spacer(minLength: 0)
                    if let secs = row.secs {
                        Text(InstallText.duration(secs)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let progress {
                    Text(InstallText.progress(progress)).font(.caption).foregroundStyle(.secondary)
                }
                if let message = row.message, row.status == .failed || row.status == .skipped || row.status == .warning {
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let command = row.command, row.status == .skipped {
                    CopyableCommand(command: command, copyLabel: "Copy the command for \(row.name)")
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 22)
    }

    @ViewBuilder private var glyph: some View {
        switch row.status {
        case nil: Image(systemName: row.alreadyDone ? "checkmark.circle" : "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .unchanged: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.orange)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: 6 Done

struct DonePage: View {
    let run: WizardRun
    let settings: AppSettings
    let library: RunnerLibrary
    let launchAtLogin: LaunchAtLogin
    let notifier: Notifier

    /// What to type after the install: the helpers live in the shell's rc file.
    static let helperCommand = "source ~/.zshrc && benchup"

    var body: some View {
        let state = run.state
        WizardScaffold("Your bench is ready",
                       explanation: state.siteURL.map { "\(state.form.site) is at \($0)" } ?? "The bench is set up.") {
            VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
                ForEach(state.skippedCommands) { skipped in
                    if let command = skipped.command {
                        VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
                            SheetOutcome(symbol: "exclamationmark.triangle.fill", tint: .orange,
                                         title: "One step was skipped",
                                         detail: "The password dialog was cancelled, so this still needs doing. Run it in Terminal:")
                            CopyableCommand(command: command, copyLabel: "Copy the command for the skipped step")
                        }
                    }
                }
                Form {
                    Section {
                        VStack(spacing: WindowMetrics.rowSpacing) {
                            RunnerPreview(runner: library.runner(settings.runnerID), state: .running, scale: 2)
                                .frame(height: Runner.pointHeight * 2)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, WindowMetrics.rowSpacing)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius, style: .continuous))
                                .accessibilityHidden(true)
                            Picker("Runner", selection: Binding(get: { settings.runnerID }, set: { settings.runnerID = $0 })) {
                                ForEach(library.all) { Text($0.name).tag($0.id) }
                            }
                        }
                    } header: {
                        Text("Menu bar runner")
                    }
                    Section {
                        Toggle("Open BenchBar at Login", isOn: Binding(get: { launchAtLogin.isOn }, set: { launchAtLogin.setEnabled($0) }))
                        notificationRow
                    } header: {
                        Text("Options")
                    }
                }
                .formStyle(.columns)
                VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
                    Text("In Terminal").font(.headline)
                    Text("Open a new Terminal window, or run this once, and benchup starts the bench:")
                        .font(.callout).foregroundStyle(.secondary)
                    CopyableCommand(command: Self.helperCommand, copyLabel: "Copy the command that loads the shell helpers")
                }
            }
        } leading: {
            Button("Take the Tour") { run.tour() }
                .help("Four short steps: the runner, the popover, the window and Terminal")
        } actions: {
            WizardBackButton(run: run)
            WizardPrimaryButton(run: run)
        }
        .onAppear {
            launchAtLogin.refresh()
            Task { await notifier.refresh() }
        }
    }

    @ViewBuilder private var notificationRow: some View {
        switch notifier.permission {
        case .notAsked:
            LabeledContent("Notifications") {
                Button("Allow Notifications") {
                    settings.notificationsEnabled = true
                    Task { await notifier.requestPermission() }
                }
            }
        case .allowed:
            LabeledContent("Notifications") {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .denied:
            LabeledContent("Notifications") {
                Button("Open Notifications…") { notifier.openSystemSettings() }
            }
        }
    }
}
