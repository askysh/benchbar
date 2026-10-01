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
    /// A newer release on offer: "Update to X…" in the footer.
    var updateOffer: UpdateOffer?
    var update: () -> Void = {}
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
    static let maxContentHeight: CGFloat = 470

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // as tall as the content, scrolling only past the cap
            CappedHeight(maxHeight: Self.maxContentHeight) {
                ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
            }
            Divider()
            Button("Scan Folder…", systemImage: "folder.badge.plus", action: commands.scanFolder)
                .buttonStyle(.borderless)
            if let version = commands.updateOffer?.version {
                Button("Update to \(version)…", systemImage: "arrow.down.circle", action: commands.update)
                    .buttonStyle(.borderless)
            }
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
                Button("Manage Bench…") { commands.manage(bench, .overview, false) }
                    .keyboardShortcut("m", modifiers: .command)
                    .help("Apps, sites and settings in the BenchBar window (⌘M)")
            }
            .controlSize(.small)
            SitesSection(bench: bench) { commands.manage(bench, .sites, false) }
            Divider()
            DoctorSection(store: store, bench: bench,
                          details: { commands.manage(bench, .health, false) },
                          repair: { commands.manage(bench, .health, true) })
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bench.name).font(.headline)
                Text("\(bench.summary.site), port \(String(bench.summary.ports.web))")
                    .font(.caption).foregroundStyle(.secondary)
                if bench.runningSince != nil, let now = bench.resources.history.latest {
                    Text("CPU \(ResourceText.cpu(now.cpuPercent)), memory \(ResourceText.memory(now.memoryBytes))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                StatePill(state: bench.state, text: BenchText.headline(
                    bench.state, reason: bench.machine.stopReason, exitCode: bench.status?.lastExitCode))
                if let since = bench.runningSince {
                    Uptime(since: since) { Text("up \($0)").font(.caption).monospacedDigit().foregroundStyle(.secondary) }
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
        let controls = store.controls(for: bench)
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

// MARK: sites

/// The bench's sites with an Open button each; the default one is what ⌘O
/// opens and benchup waits for. Sites that need a hosts line come next, so
/// they stay in view, and the command that adds the lines is one Copy away.
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
                Button(rows.count > Self.visibleRows ? "View All \(rows.count)…" : "Manage Sites…", action: manage)
                    .controlSize(.small)
                    .help("Sites in the BenchBar window")
            }
            ForEach(SiteRow.popoverRows(rows, limit: Self.visibleRows)) { row in
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
            if let fix = SiteRow.hostsFix(rows, bench: bench.path) {
                Banner(systemImage: "network", tint: .orange,
                       text: "A site has no /etc/hosts line, so its name does not resolve. Run:", command: fix)
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

/// Counts, the first checks that need attention with their fix, and the way
/// into Health and Repair. The full report lives in the window.
struct DoctorSection: View {
    let store: BenchStore
    let bench: BenchModel
    var details: () -> Void = {}
    /// Opens the Repair sheet in the BenchBar window (plan first, then a confirmation).
    var repair: () -> Void = {}
    static let visibleChecks = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Health").font(.subheadline.weight(.semibold))
                Spacer()
                if bench.isRunningDoctor {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await store.runDoctor(on: bench) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(bench.doctor == nil ? "Check health now (read only)" : "Check again (read only)")
                    .accessibilityLabel("Check health again")
                    if bench.doctor?.checks.contains(where: { $0.level != .ok && $0.action != nil }) == true {
                        Button("Repair…", action: repair).controlSize(.small)
                            .help("Shows the repair plan in the BenchBar window; nothing changes until you confirm")
                    }
                }
                Button("View Health…", action: details).controlSize(.small)
                    .keyboardShortcut("k", modifiers: .command)
            }
            if bench.doctorError != nil {
                Label("Health refresh failed. Previous results may be out of date.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let report = bench.doctor {
                if report.needsAttention.isEmpty {
                    Label("All checks passed", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text([
                        report.summary.fail > 0 ? "\(report.summary.fail) " + (report.summary.fail == 1 ? "failure" : "failures") : nil,
                        report.summary.warn > 0 ? "\(report.summary.warn) " + (report.summary.warn == 1 ? "warning" : "warnings") : nil
                    ].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.weight(.medium)).foregroundStyle(report.summary.fail > 0 ? .red : .orange)
                    ForEach(Array(report.needsAttention.prefix(Self.visibleChecks)), id: \.rowKey) { CompactCheckRow(check: $0) }
                    if report.needsAttention.count > Self.visibleChecks {
                        Button("\(report.needsAttention.count - Self.visibleChecks) more in Health…", action: details)
                            .buttonStyle(.link).font(.caption)
                    }
                }
            } else if bench.doctorError == nil {
                Text("Not checked yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One check in the popover: what is wrong in two lines, and its fix to copy.
struct CompactCheckRow: View {
    let check: DoctorCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: check.level == .fail ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(check.level == .fail ? .red : .orange).font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.label).font(.caption.weight(.medium))
                Text(check.message).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(check.message)
            }
            Spacer(minLength: 4)
            if let fix = check.fixCommand, !fix.isEmpty {
                Button("Copy Fix") { Workspace.copy(fix) }
                    .controlSize(.mini)
                    .help(fix)
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

/// How long a bench has been up, as `content` shows it, redrawn every 30
/// seconds: the popover's header and the bench page share it. The schedule
/// counts from the run's start, so a redraw of the parent keeps it.
struct Uptime<Content: View>: View {
    let since: Date
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        TimelineView(.periodic(from: since, by: 30)) { context in
            content(BenchText.uptime(since: since, now: context.date))
        }
    }
}

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

/// Sizes its content to its ideal height, up to `maxHeight`: a scroll view
/// inside is only as tall as what it scrolls, so a short popover has no gap.
struct CappedHeight: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let ideal = view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
