import SwiftUI

/// What the popover can ask the app to do.
struct AppCommands {
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
    var chooseCLI: () -> Void = {}
    var scanFolder: () -> Void = {}
    var openLogs: (BenchModel) -> Void = { _ in }
    var setup: (BenchModel, Bool) -> Void = { _, _ in }
    /// The BenchBar window at a bench's tab (true: open the Repair sheet too).
    var manage: (BenchModel, BenchTab, Bool) -> Void = { _, _, _ in }
}

/// The popover under the menu bar runner.
///
/// Shortcuts (while the popover is open):
///   ⌘U start   ⌘D stop   ⌘R restart
///   ⌘O open site   ⌘L logs   ⌘F bench folder   ⌘K view Health
///   ⌘, settings   ⌘Q quit
struct PopoverView: View {
    let store: BenchStore
    let commands: AppCommands

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 430)
            Divider()
            Button("Scan Folder…", systemImage: "folder.badge.plus", action: commands.scanFolder)
                .buttonStyle(.borderless)
            footer
        }
        .padding(14)
        .frame(width: 370)
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
                    Picker("Bench", selection: Binding(get: { store.selected?.path ?? "" }, set: { store.selectedPath = $0 })) {
                        ForEach(store.benches) { bench in
                            Text(bench.name + (store.benches.filter { $0.name == bench.name }.count > 1
                                ? " — " + URL(fileURLWithPath: bench.path).deletingLastPathComponent().lastPathComponent : ""))
                                .tag(bench.path)
                        }
                    }
                    .pickerStyle(.menu)
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
                     needsService: bench.needsService, cliReady: cliReady, otherWork: bench.isChangingScheduler || bench.activity != nil || store.waitsForOtherBench(bench))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            banners
            if bench.needsService {
                Button("Set Up Management…", systemImage: "wrench.and.screwdriver") { commands.setup(bench, false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.busyBench != nil)
            } else if bench.portConflict != nil {
                Button("Review Port Conflict…", systemImage: "exclamationmark.triangle") { commands.setup(bench, true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.busyBench != nil)
            } else {
                actionButtons
            }
            Divider()
            HStack {
                Button("Logs", systemImage: "text.alignleft") { commands.openLogs(bench) }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Folder", systemImage: "folder") { Workspace.openFolder(bench) }
                    .keyboardShortcut("f", modifiers: .command)
                Spacer()
                Button("Manage…") { commands.manage(bench, .overview, false) }
                    .keyboardShortcut("m", modifiers: .command)
            }
            .controlSize(.small)
            SitesSection(bench: bench) { commands.manage(bench, .sites, false) }
            Divider()
            DoctorSection(store: store, bench: bench) { commands.manage(bench, .health, false) }
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
            Label("Set up management to enable Start, Stop and Restart.", systemImage: "wrench.and.screwdriver")
                .font(.callout).foregroundStyle(.secondary)
        } else if bench.machine.stopReason == .broken {
            Button("Bench needs repair — review in Health…") { commands.manage(bench, .health, true) }
                .buttonStyle(.link)
        }
        if let error = bench.lastError ?? bench.refreshError, bench.portConflict == nil {
            Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                .help(error)
            Button("View Health…") { commands.manage(bench, .health, false) }.controlSize(.small)
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
                     needsService: bench.needsService, cliReady: cliReady, otherWork: bench.isChangingScheduler || bench.activity != nil || store.waitsForOtherBench(bench))
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
    var manage: () -> Void = {}
    static let visibleRows = 3

    var body: some View {
        let rows = bench.siteRows
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sites").font(.subheadline.weight(.semibold))
                Spacer()
                Button(rows.count > Self.visibleRows ? "View all \(rows.count)…" : "Manage…", action: manage)
                    .controlSize(.small)
            }
            ForEach(Array(rows.prefix(Self.visibleRows))) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.isDefault ? "star.fill" : "globe")
                        .foregroundStyle(row.isDefault ? .yellow : .secondary).font(.caption)
                        .accessibilityLabel(row.isDefault ? "Default site" : "Site")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(.callout).lineLimit(1).truncationMode(.middle).help(row.name)
                        Text(row.needsHosts ? "Hostname setup needed" : (bench.state == .running ? "Running" : "Bench is not running"))
                            .font(.caption).foregroundStyle(row.needsHosts ? .orange : .secondary)
                    }
                    Spacer(minLength: 4)
                    siteAction(row)
                }
            }

        }
    }
    @ViewBuilder private func siteAction(_ row: SiteRow) -> some View {
        if row.isDefault { siteButton(row).keyboardShortcut("o", modifiers: .command) }
        else { siteButton(row) }
    }

    private func siteButton(_ row: SiteRow) -> some View {
        Button(row.needsHosts ? "Set Up…" : "Open") {
            if row.needsHosts { manage() } else { Workspace.open(row.url) }
        }
        .controlSize(.small)
        .disabled(!row.needsHosts && bench.state != .running)
        .help(row.needsHosts ? "Review hostname setup in Sites" : row.url)
    }

}

// MARK: health summary

struct DoctorSection: View {
    let store: BenchStore
    let bench: BenchModel
    var details: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Health").font(.subheadline.weight(.semibold))
                Spacer()
                if bench.isRunningDoctor { ProgressView().controlSize(.small) }
                Button("View Health…", action: details).controlSize(.small)
                    .keyboardShortcut("k", modifiers: .command)
            }
            if bench.doctorError != nil {
                Label("Health refresh failed. Previous results may be out of date.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if let report = bench.doctor {
                if report.needsAttention.isEmpty {
                    Label("All checks passed", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text([
                        report.summary.fail > 0 ? "\(report.summary.fail) " + (report.summary.fail == 1 ? "failure" : "failures") : nil,
                        report.summary.warn > 0 ? "\(report.summary.warn) " + (report.summary.warn == 1 ? "warning" : "warnings") : nil
                    ].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(report.summary.fail > 0 ? .red : .orange)
                    ForEach(Array(report.needsAttention.prefix(2))) { check in
                        Text(check.label).font(.caption).lineLimit(1)
                    }
                }
            } else {
                Text(bench.doctorError == nil ? "Review diagnostics and repairs in Health." : "Health check failed. Open Health for details.")
                    .font(.caption).foregroundStyle(.secondary)
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
                        DisclosureGroup("Terminal instructions") {
                            Text(fix).font(.caption.monospaced()).textSelection(.enabled)
                            Button("Copy Command") { Workspace.copy(fix) }.controlSize(.small)
                        }
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
                Text(error ?? "Create one with the installer (benchbar install), or register one you already have with benchbar adopt <path>.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if error == nil {
                    // first run: the one page that gets a bench going
                    Link("New here? The Install guide sets up your first bench.", destination: BenchBarLinks.install)
                        .font(.caption)
                }
                Button("Try Again", action: retry)
            }
        }
    }
}
