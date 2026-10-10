import SwiftUI

// 3 New Bench and 4 Review.

struct NewBenchPage: View {
    let run: WizardRun
    @State private var revealPassword = false

    var body: some View {
        let state = run.state
        WizardScaffold("New Bench", explanation: "Where it goes, what it runs on and which apps it starts with.",
                       phase: state.profilesError.map { .failed($0, title: "Could not read the profiles") } ?? .ready) {
            Form {
                LabeledContent("Folder") {
                    HStack(spacing: WindowMetrics.rowSpacing) {
                        TextField("Folder", text: Binding(get: { state.form.folder }, set: { run.send(.setFolder($0)) }),
                                  prompt: Text("~/frappe-bench"))
                            .labelsHidden()
                            .onSubmit { run.send(.commitFolder) }
                        Button("Choose…", action: chooseFolder)
                    }
                }
                if let problem = state.prerequisites?.folderProblem {
                    Label(problem.message, systemImage: problem.level == .fail ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(problem.level == .fail ? .red : .orange)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                profilePicker(state)
                bundlePicker(state)
                TextField("Site name", text: Binding(get: { state.form.site }, set: { run.send(.setSite($0)) }), prompt: Text("macdev"))
                if let problem = state.siteProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Administrator password") {
                    HStack(spacing: WindowMetrics.rowSpacing) {
                        PasswordField(text: Binding(get: { state.form.adminPassword.value }, set: { run.send(.setAdminPassword($0)) }),
                                      reveal: revealPassword)
                        Toggle(isOn: $revealPassword) { Image(systemName: revealPassword ? "eye.slash" : "eye") }
                            .toggleStyle(.button)
                            .accessibilityLabel(revealPassword ? "Hide the password" : "Show the password")
                            .help(revealPassword ? "Hide the password" : "Show the password")
                    }
                }
                if state.showsPortField {
                    TextField("Port offset", text: Binding(get: { state.form.portOffset }, set: { run.send(.setPortOffset($0)) }))
                    if let taken = state.prerequisites?.check("default_ports") {
                        Text(taken.message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.columns)
            SheetNote("The password goes to the benchbar process only, never on a command line or to disk. It is the login of the new site's Administrator.")
        } actions: {
            WizardBackButton(run: run)
            WizardPrimaryButton(run: run)
        }
    }

    @ViewBuilder private func profilePicker(_ state: WizardState) -> some View {
        let choices = state.profileChoices
        Picker("Profile", selection: Binding(get: { state.form.profile }, set: { run.send(.setProfile($0)) })) {
            ForEach(choices) { choice in
                Text(choice.isTeam ? "\(choice.name) (team)" : choice.label).tag(choice.name)
            }
        }
        .disabled(choices.isEmpty)
        if let versions = choices.first(where: { $0.name == state.form.profile })?.versions {
            Text("Brings \(versions).").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func bundlePicker(_ state: WizardState) -> some View {
        Picker("Apps", selection: Binding(get: { state.form.bundle }, set: { run.send(.setBundle($0)) })) {
            ForEach(state.bundles) { Text($0.label).tag($0.name) }
        }
        .disabled(state.bundles.isEmpty)
        if let bundle = state.bundles.first(where: { $0.name == state.form.bundle }) {
            Text(bundle.apps.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        guard let path = Workspace.chooseBenchFolder(previous: run.state.resolvedFolder) else { return }
        run.send(.setFolder(path))
        run.send(.commitFolder)
    }
}

/// The password field with a reveal toggle: a secure field, or a plain one while revealed.
struct PasswordField: View {
    @Binding var text: String
    let reveal: Bool

    var body: some View {
        if reveal {
            TextField("Administrator password", text: $text).labelsHidden()
        } else {
            SecureField("Administrator password", text: $text).labelsHidden()
        }
    }
}

// MARK: 4 Review

struct ReviewPage: View {
    let run: WizardRun

    var body: some View {
        let state = run.state
        WizardScaffold("Review", explanation: "This is what BenchBar will do. Nothing has changed yet.", phase: phase(state)) {
            if let plan = state.plan {
                summary(state, plan)
                stepList(plan)
                SheetNote("Install starts it, and that is your confirmation. Steps that ask for your password show macOS's own dialog: BenchBar never sees the password. Cancel a dialog and that step is skipped with the command to run yourself.")
            }
        } actions: {
            WizardBackButton(run: run)
            WizardPrimaryButton(run: run, also: run.canStartChange)
        }
    }

    private func phase(_ state: WizardState) -> SheetPhase {
        if state.planning { return .loading("Planning the install…") }
        if let error = state.planError { return .failed(error, title: "No install plan") }
        return .ready
    }

    private func summary(_ state: WizardState, _ plan: InstallPlan) -> some View {
        let profile = state.profileChoices.first { $0.name == plan.profile }
        return VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing + 2) {
            LabeledContent("Folder") { Text((plan.bench as NSString).abbreviatingWithTildeInPath).textSelection(.enabled) }
            LabeledContent("Site") { Text(plan.webURL ?? plan.site).textSelection(.enabled) }
            LabeledContent("Profile") {
                Text(([plan.profile] + [profile?.versions]).compactMap { $0 }.joined(separator: ": ")).textSelection(.enabled)
            }
            if let bundle = state.bundles.first(where: { $0.name == plan.bundle }) {
                LabeledContent("Apps") { Text(bundle.apps.joined(separator: ", ")).textSelection(.enabled) }
            }
            if let offset = plan.portOffset, offset != 0 {
                LabeledContent("Ports") { Text("Block \(offset) (the default ports are taken)") }
            }
        }
    }

    private func stepList(_ plan: InstallPlan) -> some View {
        VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
            Text("Steps").font(.headline)
            ForEach(plan.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
                    Image(systemName: step.willRun ? "circle" : "checkmark.circle")
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(step.name)
                    if step.sudo {
                        if step.willRun {
                            Tag(text: "Asks for your password", color: .orange)
                        } else {
                            Tag(text: "Already done", color: .secondary)
                        }
                    }
                }
            }
        }
    }
}
