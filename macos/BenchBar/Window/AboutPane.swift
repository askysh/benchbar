import AppKit
import SwiftUI

/// What the About pane shows and does, kept by the app so a check or a
/// report in progress survives switching panes.
@Observable
final class AboutModel {
    let updates: UpdateChecker
    let bugReport: BugReport
    /// "benchbar 0.5.0", the first line of `benchbar --version`.
    private(set) var cliVersion: String?

    @ObservationIgnored private let store: BenchStore

    init(store: BenchStore, updates: UpdateChecker = UpdateChecker(), bugReport: BugReport? = nil) {
        self.store = store
        self.updates = updates
        self.bugReport = bugReport ?? BugReport(store: store)
    }

    func loadCLIVersion() async {
        guard let client = store.cliClient else { cliVersion = nil; return }
        cliVersion = try? await client.version()
    }
}

/// Report a Bug: `benchbar report --json`, the zip shown in Finder, and a
/// new issue with the versions filled in.
@Observable
final class BugReport {
    enum State: Equatable {
        case ready
        case running
        case done(BugReportFile, issue: URL)
        case failed(String, issue: URL)
    }

    private(set) var state: State = .ready

    @ObservationIgnored private let store: BenchStore
    @ObservationIgnored var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    @ObservationIgnored var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored var macOS: String = BenchBarLinks.macOSVersion
    @ObservationIgnored var appVersion: String = BenchBarLinks.appVersion

    init(store: BenchStore) {
        self.store = store
    }

    /// Back to the explanation, for the next time the sheet opens.
    func reset() {
        if state != .running { state = .ready }
    }

    func create() async {
        guard state != .running else { return }
        guard let client = store.cliClient else {
            state = .failed("The benchbar command line tool was not found, so there is no report. The issue page still opens with your versions.",
                            issue: issueURL(cli: nil))
            return
        }
        state = .running
        let cli = try? await client.version()
        let issue = issueURL(cli: cli)
        do throws(CLIError) {
            let file = try await client.report(bench: store.selected?.path)
            state = .done(file, issue: issue)
            reveal(URL(fileURLWithPath: file.zip))
            openURL(issue)
        } catch {
            state = .failed(Self.message(for: error), issue: issue)
        }
    }

    func issueURL(cli: String?) -> URL {
        BenchBarLinks.newBugReport(macOS: macOS, app: appVersion, cli: cli)
    }

    /// A CLI older than 0.5.5 has no `report --json`: it writes the zip
    /// and prints text, which does not decode.
    static func message(for error: CLIError) -> String {
        if case .invalidJSON = error {
            return "This benchbar is older than the app and cannot report to it. Run benchbar report in Terminal: it writes the zip to your Desktop."
        }
        return error.localizedDescription
    }
}

/// The About pane of the BenchBar window.
struct AboutPane: View {
    let store: BenchStore
    let model: AboutModel
    @Bindable var router: WindowRouter

    @State private var showBugReport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            form
        }
        .task(id: cliPath) { await model.loadCLIVersion() }
        .onAppear(perform: handleRequests)
        .onChange(of: router.bugReportRequested) { handleRequests() }
        .onChange(of: router.updateCheckRequested) { handleRequests() }
        .sheet(isPresented: $showBugReport, onDismiss: { model.bugReport.reset() }) {
            BugReportSheet(report: model.bugReport) { showBugReport = false }
        }
    }

    private var cliPath: String? {
        if case .ready(let url) = store.cli { return url.path }
        return nil
    }

    /// The Help menu and the app menu open this pane with a request.
    private func handleRequests() {
        if router.bugReportRequested {
            router.bugReportRequested = false
            showBugReport = true
        }
        if router.updateCheckRequested {
            router.updateCheckRequested = false
            Task { await model.updates.check() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("BenchBar").font(.title.weight(.semibold))
                Text("Version \(BenchBarLinks.appVersion) (\(BenchBarLinks.appBuild))")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Frappe benches on your Mac, from the menu bar.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
    }

    private var form: some View {
        Form {
            Section {
                LabeledContent("BenchBar") {
                    Text("\(BenchBarLinks.appVersion) (build \(BenchBarLinks.appBuild))").textSelection(.enabled)
                }
                LabeledContent("Command line tool") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(model.cliVersion ?? (cliPath == nil ? "not found" : "…")).textSelection(.enabled)
                        if let cliPath {
                            Text(cliPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                updateRow
            } header: {
                Text("Versions")
            }
            Section {
                LinkRow(title: "Documentation", detail: "benchbar.akashmishra.com", url: BenchBarLinks.docs)
                LinkRow(title: "Release notes", detail: "What changed in each version", url: BenchBarLinks.changelog)
                LinkRow(title: "Source code", detail: "github.com/askysh/benchbar", url: BenchBarLinks.repository)
                LabeledContent {
                    Button("Report a Bug…") { showBugReport = true }
                } label: {
                    Text("Found a bug?")
                    Text("A redacted diagnostics zip and a new issue with your versions.")
                }
            } header: {
                Text("Help")
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
                Text("BenchBar is free software under the MIT License.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Frappe and ERPNext are trademarks of Frappe Technologies; BenchBar is not affiliated with or endorsed by them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var updateRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                switch model.updates.state {
                case .idle:
                    EmptyView()
                case .checking:
                    ProgressView().controlSize(.small)
                case .done(.upToDate(let latest)):
                    Label("Up to date (latest is \(latest))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .done(.available(let version, let page)):
                    Label("\(version) available", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Button("Release Page") { NSWorkspace.shared.open(page) }
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Button("Check for Updates") { Task { await model.updates.check() } }
                    .disabled(model.updates.state == .checking)
            }
        } label: {
            Text("Updates")
            Text("Asks GitHub for the latest release, only when you click.")
        }
    }
}

/// A row that opens a web page, with the address underneath.
private struct LinkRow: View {
    let title: String
    let detail: String
    let url: URL

    var body: some View {
        LabeledContent {
            Button("Open") { NSWorkspace.shared.open(url) }
        } label: {
            Text(title)
            Text(detail)
        }
        .help(url.absoluteString)
    }
}

/// Explains what the report holds before anything runs, then shows where
/// the zip went.
struct BugReportSheet: View {
    let report: BugReport
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Report a Bug", systemImage: "ladybug").font(.title3.weight(.semibold))
            switch report.state {
            case .ready:
                explanation
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                    Button("Create Report") { Task { await report.create() } }
                        .keyboardShortcut(.defaultAction)
                }
            case .running:
                explanation
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Running benchbar report…").foregroundStyle(.secondary)
                    Spacer()
                }
            case .done(let file, let issue):
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: file.zip).lastPathComponent).font(.callout.weight(.medium)).textSelection(.enabled)
                        Text("\(file.redactions) lines redacted. The zip is selected in Finder and the issue page is open in your browser: describe what happened and attach the zip.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                HStack {
                    Button("Show in Finder") { report.reveal(URL(fileURLWithPath: file.zip)) }
                    Button("Open Issue Page") { report.openURL(issue) }
                    Spacer()
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                }
            case .failed(let message, let issue):
                Label {
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                HStack {
                    Button("Open Issue Page") { report.openURL(issue) }
                    Spacer()
                    Button("Close", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                    Button("Try Again") { Task { await report.create() } }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BenchBar runs benchbar report, which writes a zip to your Desktop: doctor and status, the versions of everything involved, the login agent, Procfile.lean and the last lines of the logs.")
            Text("It has no secrets, no personal paths and no names: passwords, keys and tokens are masked, your home folder, username and the names of this Mac are replaced, and site configs are reduced to their key names. REDACTIONS.txt inside lists every replacement.")
            Text("Then Finder shows the zip and GitHub opens a new issue with your macOS and BenchBar versions filled in. Nothing is sent until you attach the zip yourself.")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

nonisolated enum MCPSnippet {
    static let claude = "claude mcp add benchbar -- benchbar mcp"
}
