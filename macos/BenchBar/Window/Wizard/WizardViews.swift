import SwiftUI

/// One page of the first run wizard: the same layout as a sheet (SheetScaffold),
/// as a page in the window's content area. A title, one line, the content
/// (scrolling), then the footer: the secondary actions on the left, Back or
/// Cancel to the left of the one primary action. Return is the primary action
/// and Esc is Back (Cancel on the first page).
struct WizardScaffold<Content: View, Leading: View, Actions: View>: View {
    let title: String
    let explanation: String?
    var phase: SheetPhase = .ready
    @ViewBuilder var content: Content
    @ViewBuilder var leading: Leading
    @ViewBuilder var actions: Actions

    init(_ title: String, explanation: String? = nil, phase: SheetPhase = .ready,
         @ViewBuilder content: () -> Content, @ViewBuilder leading: () -> Leading, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.explanation = explanation
        self.phase = phase
        self.content = content()
        self.leading = leading()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing + 2) {
                Text(title).font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let explanation {
                    Text(explanation).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, WindowMetrics.spacing)
            ScrollView {
                VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
                    SheetStatus(phase: phase)
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer.padding(.top, WindowMetrics.spacing)
        }
        .padding(WindowMetrics.sheetPadding)
        .frame(maxWidth: WindowMetrics.wizardWidth, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: WindowMetrics.rowSpacing) {
            if case .running(let text) = phase {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.secondary).lineLimit(1)
            }
            leading
            Spacer(minLength: WindowMetrics.rowSpacing)
            actions
        }
    }
}

extension WizardScaffold where Leading == EmptyView {
    init(_ title: String, explanation: String? = nil, phase: SheetPhase = .ready,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.init(title, explanation: explanation, phase: phase, content: content, leading: { EmptyView() }, actions: actions)
    }
}

/// The first run wizard, in the window's content area.
struct WizardView: View {
    let run: WizardRun
    let settings: AppSettings
    let library: RunnerLibrary
    let launchAtLogin: LaunchAtLogin
    let notifier: Notifier

    var body: some View {
        let state = run.state
        Group {
            switch state.page {
            case .welcome: WelcomePage(run: run, settings: settings, library: library)
            case .cliOnly: CLIOnlyPage(run: run)
            case .check: CheckPage(run: run, settings: settings, library: library)
            case .newBench: NewBenchPage(run: run)
            case .review: ReviewPage(run: run)
            case .install: InstallPage(run: run)
            case .done: DonePage(run: run, settings: settings, library: library, launchAtLogin: launchAtLogin, notifier: notifier)
            }
        }
        .navigationTitle("New Bench")
    }
}

// MARK: footer buttons shared by the pages

/// Back, or Cancel on the first page: Esc.
struct WizardBackButton: View {
    let run: WizardRun

    var body: some View {
        if let title = run.state.backTitle, !(run.state.page == .welcome && run.store.benches.isEmpty) {
            Button(title, role: .cancel) { run.back() }
                .keyboardShortcut(.cancelAction)
        }
    }
}

/// The page's one primary action: Return.
struct WizardPrimaryButton: View {
    let run: WizardRun
    /// More that has to be true before the button works (the store is free).
    var also = true

    var body: some View {
        if let primary = run.state.primary {
            Button(primary.title) { run.primary() }
                .keyboardShortcut(.defaultAction)
                .primaryAction()
                .disabled(!primary.enabled || !also)
        }
    }
}

// MARK: 1 Welcome

struct WelcomePage: View {
    let run: WizardRun
    let settings: AppSettings
    let library: RunnerLibrary

    var body: some View {
        WizardScaffold("BenchBar",
                       explanation: "Sets up a Frappe bench on this Mac, keeps it running and tells you when it crashes.") {
            VStack(spacing: WindowMetrics.spacing) {
                RunnerPreview(runner: library.runner(settings.runnerID), state: .running, scale: 3)
                    .frame(height: Runner.pointHeight * 3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, WindowMetrics.paneInset)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius, style: .continuous))
                    .accessibilityHidden(true)
                if case .missing(let error) = run.store.cli {
                    PaneBanner(symbol: "questionmark.folder", tint: .orange, title: error.localizedDescription,
                               detail: error.recoverySuggestion)
                }
                Button("Just the Command Line Tool") { run.send(.chooseCLIOnly) }
                    .buttonStyle(.link)
                    .help("Install benchbar without the app's wizard: the Homebrew line and the one line installer")
            }
        } leading: {
            Button("I Already Have a Bench") { run.send(.chooseExistingBench) }
                .help("Find the benches in a folder and set them up")
        } actions: {
            WizardBackButton(run: run)
            WizardPrimaryButton(run: run)
        }
    }
}

// MARK: Just the command line tool

struct CLIOnlyPage: View {
    let run: WizardRun

    /// The one line installer from docs/install.md.
    static let installerLine = "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash"

    var body: some View {
        WizardScaffold("Just the Command Line Tool",
                       explanation: "benchbar works without the app. Run one of these in Terminal, then benchbar install.") {
            VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
                VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
                    Text("Homebrew").font(.headline)
                    CopyableCommand(command: Homebrew.installCLI, copyLabel: "Copy the Homebrew command")
                }
                VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
                    Text("The one line installer").font(.headline)
                    CopyableCommand(command: Self.installerLine, copyLabel: "Copy the one line installer")
                }
                SheetNote("The installer checks the Command Line Tools and Homebrew first, and never runs sudo itself. docs: benchbar.akashmishra.com/install")
            }
        } actions: {
            WizardBackButton(run: run)
            WizardPrimaryButton(run: run)
        }
    }
}

// MARK: 2 Check Your Mac

struct CheckPage: View {
    let run: WizardRun
    let settings: AppSettings
    let library: RunnerLibrary

    var body: some View {
        let state = run.state
        WizardScaffold("Check Your Mac",
                       explanation: "A bench needs these on the Mac first. Anything missing shows what to do about it.",
                       phase: phase) {
            VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
                RunnerPreview(runner: library.runner(settings.runnerID), state: state.runnerState, scale: 2)
                    .frame(height: Runner.pointHeight * 2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, WindowMetrics.rowSpacing)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius, style: .continuous))
                    .accessibilityHidden(true)
                ForEach(PrerequisiteRows.rows(state.prerequisites)) { row in
                    PrerequisiteRowView(row: row, run: run)
                    Divider()
                }
                if let report = state.prerequisites, !report.canContinue {
                    SheetNote("Fix what is marked red, then Check Again. Continue is possible when nothing is red.", tint: .orange)
                }
            }
        } leading: {
            Button("Check Again") { run.send(.checkAgain) }
                .disabled(state.checking)
            if state.checking && state.prerequisites != nil {
                ProgressView().controlSize(.small)
            }
        } actions: {
            WizardBackButton(run: run)
            WizardPrimaryButton(run: run)
        }
    }

    private var phase: SheetPhase {
        let state = run.state
        if let error = state.checkError { return .failed(error, title: "Could not check this Mac") }
        if state.prerequisites == nil { return .loading("Checking your Mac…") }
        return .ready
    }
}

struct PrerequisiteRowView: View {
    let row: PrerequisiteRow
    let run: WizardRun

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityLabel(levelWord)
            VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing + 2) {
                Text(row.label).font(.body.weight(.medium))
                if !row.message.isEmpty {
                    Text(row.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch row.action {
                case .none:
                    EmptyView()
                case .installCommandLineTools:
                    HStack(spacing: WindowMetrics.rowSpacing) {
                        Button("Install Command Line Tools…") { Task { await run.startCommandLineTools() } }
                        if run.openedCommandLineTools {
                            Text("Apple's installer is open. This row updates when it finishes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let message = run.commandLineToolsMessage {
                        Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                case .copy(let command):
                    CopyableCommand(command: command, copyLabel: "Copy the command for \(row.label)")
                    SheetNote("BenchBar never runs this. Run it in Terminal, then Check Again.")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch row.level {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch row.level {
        case .ok: .green
        case .warn: .orange
        case .fail: .red
        case .unknown: .secondary
        }
    }

    private var levelWord: String {
        switch row.level {
        case .ok: "ok"
        case .warn: "warning"
        case .fail: "failed"
        case .unknown: "unknown"
        }
    }
}
