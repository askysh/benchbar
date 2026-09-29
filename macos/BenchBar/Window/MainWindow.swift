import SwiftUI

/// Where the BenchBar window is: an app pane, or one bench's page and tab.
nonisolated enum WindowPane: Hashable, Sendable {
    case general, menuBar, profiles, about, discovery
    case bench(String)
}

nonisolated enum BenchTab: String, CaseIterable, Hashable, Sendable, Identifiable {
    case overview = "Overview", sites = "Sites", apps = "Apps", health = "Health"
    var id: String { rawValue }
}

/// Lets the popover, the menu and notifications open the window at a pane.
@Observable
final class WindowRouter {
    var pane: WindowPane? = .general
    var benchTab: BenchTab = .overview
    /// Set to open the Repair sheet on the bench page when it appears.
    var repairRequested = false
    var scanRequested = false
    var setupRequest: String?
    var startAfterSetup = false
    /// Set by the Help menu: the About pane opens its Report a Bug sheet.
    var bugReportRequested = false
    /// Set by the app menu: the About pane checks for updates.
    var updateCheckRequested = false
    /// Set by Help > Keyboard Shortcuts: General scrolls to that section.
    var scrollTarget: String?
    /// Why a benchbar:// link did nothing (no such bench, which bench):
    /// shown on top of the window until dismissed.
    var notice: String?

    func show(bench path: String, tab: BenchTab = .overview) {
        pane = .bench(path)
        benchTab = tab
    }
}

/// The BenchBar window: the app's settings on top, every bench below, like
/// System Settings. Everything here runs the CLI; the popover stays the
/// quick path for start, stop and open.
struct MainWindowView: View {
    let store: BenchStore
    @Bindable var router: WindowRouter
    let workbench: Workbench
    let about: AboutModel
    let discovery: BenchDiscovery
    let makeSettings: (SettingsView.Part) -> SettingsView

    var body: some View {
        NavigationSplitView {
            List(selection: $router.pane) {
                Section("BenchBar") {
                    Label("General", systemImage: "gearshape").tag(WindowPane.general)
                    Label("Menu Bar", systemImage: "menubar.rectangle").tag(WindowPane.menuBar)
                    Label("Team Profiles", systemImage: "person.2").tag(WindowPane.profiles)
                    Label("About", systemImage: "info.circle").tag(WindowPane.about)
                }
                Section("Benches") {
                    Label("Find Benches", systemImage: "folder.badge.plus").tag(WindowPane.discovery)
                    if store.benches.isEmpty {
                        Text("No bench yet").foregroundStyle(.secondary)
                    }
                    ForEach(store.benches) { bench in
                        HStack(spacing: 8) {
                            Circle().fill(StatePill.color(for: bench.state)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bench.name)
                                if store.benches.filter({ $0.name == bench.name }).count > 1 {
                                    Text(URL(fileURLWithPath: bench.path).deletingLastPathComponent().lastPathComponent)
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .help(bench.path)
                            Spacer()
                            if bench.activity != nil || bench.pending != nil || bench.isChangingScheduler {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .tag(WindowPane.bench(bench.path))
                        .contextMenu { BenchContextMenu(store: store, bench: bench) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .frame(minWidth: 560, minHeight: 460)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let notice = router.notice {
                        NoticeBanner(text: notice) { router.notice = nil }
                            .padding([.horizontal, .top], 16)
                    }
                }
        }
    }

    @ViewBuilder private var detail: some View {
        switch router.pane {
        case .general, .none:
            makeSettings(.general).navigationTitle("General")
        case .menuBar:
            makeSettings(.menuBar).navigationTitle("Menu Bar")
        case .profiles:
            ProfilesPane(store: store, workbench: workbench).navigationTitle("Team Profiles")
        case .about:
            AboutPane(store: store, model: about, router: router).navigationTitle("About BenchBar")
        case .discovery:
            DiscoveryPane(discovery: discovery, router: router).navigationTitle("Find Benches")
        case .bench(let path):
            if let bench = store.benches.first(where: { $0.path == path }) {
                BenchPage(store: store, workbench: workbench, bench: bench, router: router)
                    .navigationTitle(bench.name)
                    .id(bench.path)
            } else {
                ContentUnavailableView("This bench is gone", systemImage: "questionmark.folder",
                                       description: Text("benchbar list no longer reports it."))
            }
        }
    }
}

/// A message for the whole window, for now only from a benchbar:// link.
struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "link").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("A BenchBar link did nothing").font(.callout.weight(.medium))
                Text(text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Dismiss")
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The banner with the outcome of the last change, at the top of a pane.
struct ChangeResultBanner: View {
    let workbench: Workbench
    /// Only the outcome of a change made here: a bench's path, or the profiles scope.
    let scope: String

    var body: some View {
        if let result = workbench.result, result.scope == scope {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.succeeded ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.succeeded ? "\(result.title): done" : "\(result.title): failed").font(.callout.weight(.medium))
                    if let error = result.error {
                        Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                Button { workbench.result = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Dismiss")
            }
            .padding(10)
            .background((result.succeeded ? Color.green : Color.red).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
