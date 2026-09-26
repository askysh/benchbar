import SwiftUI

/// What the popover can ask the app to do.
struct AppCommands {
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
    var chooseCLI: () -> Void = {}
    var openLogs: (BenchModel) -> Void = { _ in }
}

/// The popover under the menu bar runner.
///
/// Shortcuts (while the popover is open):
///   ⌘U start   ⌘D stop   ⌘R restart
///   ⌘O open site   ⌘L logs   ⌘F bench folder   ⌘K run doctor
///   ⌘, settings   ⌘Q quit
struct PopoverView: View {
    let store: BenchStore
    let commands: AppCommands

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder private var content: some View {
        switch store.cli {
        case .searching:
            ProgressView("Looking for benchbar").controlSize(.small)
        case .missing(let error):
            CLIMissingView(error: error, choose: commands.chooseCLI) {
                Task { await store.useCLI(path: store.settings.cliPath) }
            }
        case .ready:
            if store.benches.isEmpty {
                NoBenchView(error: store.listError, loading: store.isLoading) {
                    Task { await store.reloadBenches() }
                }
            } else {
                if store.benches.count > 1 {
                    BenchListSection(store: store)
                    Divider()
                }
                if let bench = store.selected {
                    BenchPanel(store: store, bench: bench, commands: commands)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: commands.openSettings)
                .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button("Quit BenchBar", action: commands.quit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

// MARK: one bench

struct BenchPanel: View {
    let store: BenchStore
    let bench: BenchModel
    let commands: AppCommands

    private var controls: BenchControls {
        var cliReady = false
        if case .ready = store.cli { cliReady = true }
        return .make(state: bench.state, reason: bench.machine.stopReason, pending: bench.pending,
                     needsService: bench.needsService, cliReady: cliReady, otherWork: bench.isChangingScheduler || store.waitsForOtherBench(bench))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            banners
            actionButtons
            Divider()
            VStack(spacing: 2) {
                RowButton("Open site", systemImage: "safari", shortcut: "O") { Workspace.openSite(bench) }
                    .keyboardShortcut("o", modifiers: .command)
                RowButton("Open logs", systemImage: "text.alignleft", shortcut: "L") { commands.openLogs(bench) }
                    .keyboardShortcut("l", modifiers: .command)
                RowButton("Open bench folder", systemImage: "folder", shortcut: "F") { Workspace.openFolder(bench) }
                    .keyboardShortcut("f", modifiers: .command)
            }
            SitesSection(bench: bench)
            Divider()
            DoctorSection(store: store, bench: bench)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bench.name).font(.headline)
                Text("\(bench.summary.site), port \(String(bench.summary.ports.web))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                StatePill(state: bench.state, text: BenchText.headline(
                    bench.state, reason: bench.machine.stopReason, exitCode: bench.status?.lastExitCode))
                if let since = bench.runningSince {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("up \(BenchText.uptime(since: since, now: context.date))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var banners: some View {
        if bench.needsService {
            Banner(systemImage: "wrench.and.screwdriver", tint: .orange,
                   text: "This bench has no BenchBar agent yet. Run this once in Terminal:",
                   command: BenchText.command("repair", bench: bench.path))
        } else if bench.machine.stopReason == .broken {
            Banner(systemImage: "wrench.and.screwdriver", tint: .orange,
                   text: "Parts of the bench are missing (env, node modules or assets). Run:",
                   command: BenchText.command("repair", bench: bench.path))
        }
        if let error = bench.lastError ?? bench.refreshError {
            Banner(systemImage: "exclamationmark.triangle", tint: .red, text: error, command: nil)
        }
    }

    private var actionButtons: some View {
        let controls = controls
        return HStack(spacing: 8) {
            ActionButton(title: "Start", systemImage: "play.fill", busy: controls.busy == .up, enabled: controls.canStart) {
                Task { await store.perform(.up, on: bench) }
            }
            .keyboardShortcut("u", modifiers: .command)
            ActionButton(title: "Stop", systemImage: "stop.fill", busy: controls.busy == .down, enabled: controls.canStop) {
                Task { await store.perform(.down, on: bench) }
            }
            .keyboardShortcut("d", modifiers: .command)
            ActionButton(title: "Restart", systemImage: "arrow.clockwise", busy: controls.busy == .restart, enabled: controls.canRestart) {
                Task { await store.perform(.restart, on: bench) }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}

// MARK: several benches

/// Every bench with its state, uptime and actions, above the selected
/// bench's detail. The row buttons act on their own bench without changing
/// the selection; clicking the row selects it.
struct BenchListSection: View {
    let store: BenchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Benches").font(.subheadline.weight(.semibold))
                Spacer()
                Text(BenchAggregate.upText(store.benches.map(\.state)))
                    .font(.caption.weight(.medium)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            if store.benches.count > Self.visibleRows {
                // many benches: the list scrolls, so the detail and the footer stay on screen
                ScrollView {
                    rows
                }
                .frame(height: Self.rowHeight * CGFloat(Self.visibleRows))
            } else {
                rows
            }
        }
    }

    static let visibleRows = 4
    static let rowHeight: CGFloat = 44

    private var rows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.benches) { bench in
                BenchRow(store: store, bench: bench, selected: bench.path == store.selected?.path)
            }
        }
    }
}

struct BenchRow: View {
    let store: BenchStore
    let bench: BenchModel
    let selected: Bool
    @State private var hovering = false

    private var controls: BenchControls {
        var cliReady = false
        if case .ready = store.cli { cliReady = true }
        return .make(state: bench.state, reason: bench.machine.stopReason, pending: bench.pending,
                     needsService: bench.needsService, cliReady: cliReady, otherWork: bench.isChangingScheduler || store.waitsForOtherBench(bench))
    }

    var body: some View {
        let controls = controls
        HStack(spacing: 8) {
            Circle().fill(StatePill.color(for: bench.state)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(bench.name).font(.callout.weight(selected ? .semibold : .regular))
                Group {
                    if let since = bench.runningSince {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text("\(StatusItemController.word(for: bench.state)), up \(BenchText.uptime(since: since, now: context.date))")
                        }
                    } else {
                        Text(StatusItemController.word(for: bench.state))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let busy = controls.busy {
                ProgressView().controlSize(.mini).help("\(busy.rawValue) in progress")
            } else {
                RowIcon("play.fill", help: "Start \(bench.name)", enabled: controls.canStart) {
                    Task { await store.perform(.up, on: bench) }
                }
                RowIcon("stop.fill", help: "Stop \(bench.name)", enabled: controls.canStop) {
                    Task { await store.perform(.down, on: bench) }
                }
                RowIcon("arrow.clockwise", help: "Restart \(bench.name)", enabled: controls.canRestart) {
                    Task { await store.perform(.restart, on: bench) }
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(selected ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.06) : .clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .onTapGesture { store.selectedPath = bench.path }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(bench.name), \(StatusItemController.word(for: bench.state))")
    }
}

struct RowIcon: View {
    let systemImage: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    init(_ systemImage: String, help: String, enabled: Bool, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: sites

/// The bench's sites with an Open button each; the default one is what ⌘O
/// opens and benchup waits for. A missing hosts line shows its fix.
struct SitesSection: View {
    let bench: BenchModel

    var body: some View {
        let rows = bench.siteRows
        VStack(alignment: .leading, spacing: 4) {
            if rows.count > 1 || rows.contains(where: \.needsHosts) {
                Text("Sites").font(.subheadline.weight(.semibold))
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.isDefault ? "star.fill" : "globe")
                            .foregroundStyle(row.isDefault ? .yellow : .secondary).font(.caption)
                            .help(row.isDefault ? "Default site (⌘O)" : "")
                        Text(row.name).font(.callout)
                        if row.needsHosts {
                            Text("no hosts entry").font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Open") { Workspace.open(row.url) }
                            .controlSize(.small)
                            .help(row.url)
                    }
                }
                if let fix = SiteRow.hostsFix(rows, bench: bench.path) {
                    Banner(systemImage: "network", tint: .orange,
                           text: "A site has no /etc/hosts line, so its name does not resolve. Run:", command: fix)
                }
            }
        }
    }
}

// MARK: doctor

struct DoctorSection: View {
    let store: BenchStore
    let bench: BenchModel
    @State private var showPassing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Doctor").font(.subheadline.weight(.semibold))
                if let report = bench.doctor {
                    Text("\(report.summary.ok) ok, \(report.summary.warn) warn, \(report.summary.fail) fail")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if bench.isRunningDoctor {
                    ProgressView().controlSize(.small)
                } else {
                    Button(bench.doctor == nil ? "Run doctor" : "Run again") {
                        Task { await store.runDoctor(on: bench) }
                    }
                    .keyboardShortcut("k", modifiers: .command)
                    .controlSize(.small)
                    .help("Read only: benchbar doctor --json (⌘K)")
                }
            }
            if let error = bench.doctorError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let report = bench.doctor {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if report.needsAttention.isEmpty {
                            Label("Every check passes.", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                        ForEach(report.needsAttention) { CheckRow(check: $0) }
                        if !report.passing.isEmpty {
                            DisclosureGroup("\(report.passing.count) passing", isExpanded: $showPassing) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(report.passing) { CheckRow(check: $0) }
                                }
                                .padding(.top, 4)
                            }
                            .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
    }
}

struct CheckRow: View {
    let check: DoctorCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.label).font(.caption.weight(.medium))
                if check.level != .ok {
                    Text(check.message).font(.caption).foregroundStyle(.secondary)
                    if let fix = check.fixCommand, !fix.isEmpty {
                        Text(fix).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var icon: String {
        switch check.level {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var color: Color {
        switch check.level {
        case .ok: .green
        case .warn: .orange
        case .fail: .red
        case .unknown: .secondary
        }
    }
}

// MARK: small pieces

struct StatePill: View {
    let state: BenchState
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color { Self.color(for: state) }

    static func color(for state: BenchState) -> Color {
        switch state {
        case .running: .green
        case .starting: .yellow
        case .crashed, .paused: .red
        case .stopped, .unknown: .gray
        }
    }
}

struct ActionButton: View {
    let title: String
    let systemImage: String
    let busy: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(!enabled)
    }
}

/// A full width row that highlights under the pointer, like a menu item.
struct RowButton: View {
    let title: String
    let systemImage: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, systemImage: String, shortcut: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage).frame(width: 18)
                Text(title)
                Spacer()
                Text("⌘\(shortcut)").foregroundStyle(.secondary).font(.caption)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct Banner: View {
    let systemImage: String
    let tint: Color
    let text: String
    let command: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: systemImage)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let command {
                HStack {
                    Text(command).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button("Copy") { Workspace.copy(command) }.controlSize(.mini)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct CLIMissingView: View {
    let error: CLIError
    let choose: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error.localizedDescription, systemImage: "questionmark.folder")
                .font(.headline)
            if let hint = error.recoverySuggestion {
                Text(hint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Choose benchbar…", action: choose)
                Button("Try Again", action: retry)
            }
        }
    }
}

struct NoBenchView: View {
    let error: String?
    let loading: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loading {
                ProgressView("Loading benches").controlSize(.small)
            } else {
                Label("No bench found", systemImage: "tray").font(.headline)
                Text(error ?? "Create one with the installer (benchbar install), or point the CLI at yours with benchbar repair --bench-dir <path>.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry)
            }
        }
    }
}
