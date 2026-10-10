import SwiftUI

/// Where the BenchBar window is: an app pane, the first run wizard, or one
/// bench's page and tab. General, Menu Bar and About are not panes any more:
/// Settings (⌘,) and About BenchBar are their own small windows.
nonisolated enum WindowPane: Hashable, Sendable {
    case profiles, discovery, wizard
    case bench(String)
}

nonisolated enum BenchTab: String, CaseIterable, Hashable, Sendable, Identifiable {
    case overview = "Overview", sites = "Sites", apps = "Apps", health = "Health"
    var id: String { rawValue }
}

/// Lets the popover, the menu and notifications open the window at a pane.
@Observable
final class WindowRouter {
    /// nil: the window's own first page, the wizard on a Mac without a bench,
    /// else the first bench (`MainWindowView.pane`).
    var pane: WindowPane?
    var benchTab: BenchTab = .overview
    /// The site row of the sidebar that opened the Sites tab, to draw it selected.
    var sidebarSite: String?
    /// Set to open the Repair sheet on the bench page when it appears.
    var repairRequested = false
    var scanRequested = false
    var setupRequest: String?
    var startAfterSetup = false
    /// Set by the popover: the Sites tab of this bench opens its Add Hosts Lines sheet.
    var hostsRequest: String?
    /// Set by the Help menu: the About window opens its Report a Bug sheet.
    var bugReportRequested = false
    /// Set by the app menu: the About window checks for updates.
    var updateCheckRequested = false
    /// Set by Help > Show Walkthrough and the wizard's Take the Tour: the window shows the sheet.
    var walkthroughRequested = false
    /// Set by Help > Keyboard Shortcuts: General scrolls to that section.
    var scrollTarget: String?
    /// Why a benchbar:// link did nothing (no such bench, which bench):
    /// shown on top of the window until dismissed.
    var notice: String?
    /// A benchbar://profile link: Team Profiles opens the sheet prefilled.
    var profileRequest: URLRouter.ProfileLink?

    func show(bench path: String, tab: BenchTab = .overview) {
        pane = .bench(path)
        benchTab = tab
        sidebarSite = nil
    }
}

/// The BenchBar window: the benches (each with its sites), Team Profiles and
/// Find Benches in the sidebar, the first run wizard as the empty state.
/// Everything here runs the CLI; the popover stays the quick path for start,
/// stop and open.
struct MainWindowView: View {
    let store: BenchStore
    @Bindable var router: WindowRouter
    let workbench: Workbench
    let about: AboutModel
    let discovery: BenchDiscovery
    let wizard: WizardView
    var settings: AppSettings?

    /// The page shown: the router's, else the first bench, else the wizard.
    /// nil while the bench list has not been read yet.
    var pane: WindowPane? {
        if let pane = router.pane { return pane }
        if let first = store.benches.first { return .bench(first.path) }
        return store.hasLoadedBenches || !cliReady ? .wizard : nil
    }

    /// Once, on its own: the first time the window shows a bench.
    private func offerWalkthrough() {
        guard let settings, WalkthroughModel.shouldShowOnItsOwn(
            seen: settings.walkthroughSeen, benchCount: store.benches.count, onWizard: pane == .wizard || pane == nil) else { return }
        settings.walkthroughSeen = true
        router.walkthroughRequested = true
    }

    private var cliReady: Bool {
        if case .ready = store.cli { return true }
        return false
    }

    /// The sidebar's selected row.
    var selection: SidebarItem? {
        switch pane {
        case .bench(let path):
            if router.benchTab == .sites, let site = router.sidebarSite { return .site(bench: path, name: site) }
            return .bench(path)
        case .profiles: return .profiles
        case .discovery: return .discovery
        case .wizard, .none: return nil
        }
    }

    private func select(_ item: SidebarItem?) {
        switch item {
        case .bench(let path): router.show(bench: path)
        case .site(let path, let name):
            router.show(bench: path, tab: .sites)
            router.sidebarSite = name
        case .profiles: router.pane = .profiles
        case .discovery: router.pane = .discovery
        case .none: break
        }
    }

    var body: some View {
        content
            // the page the window opens on becomes the router's: the window
            // reports the bench whose Overview (with the charts) is shown
            .onChange(of: pane, initial: true) { _, shown in
                if router.pane == nil, let shown { router.pane = shown }
                offerWalkthrough()
            }
            .onChange(of: store.benches.count) { offerWalkthrough() }
            .sheet(isPresented: $router.walkthroughRequested) {
                WalkthroughSheet { router.walkthroughRequested = false }
            }
    }

    private var content: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // a closure, not the method reference select(_:): the Swift 6.3
                // compiler of Xcode 26.6 crashed emitting its isolated thunk
                MainSidebar(store: store, model: SidebarModel(benches: store.benches),
                            selection: Binding(get: { selection }, set: { select($0) }))
                Divider()
                SidebarFooter(router: router, wizard: wizard.run)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .frame(minWidth: 560, minHeight: 460)
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if let offer = about.offer, offer.showsBanner {
                            UpdateBanner(offer: offer).padding([.horizontal, .top], WindowMetrics.paneInset)
                        }
                        if let notice = router.notice {
                            NoticeBanner(text: notice) { router.notice = nil }
                                .padding([.horizontal, .top], WindowMetrics.paneInset)
                        }
                    }
                }
        }
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .none:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .wizard:
            wizard
        case .profiles:
            ProfilesPane(store: store, workbench: workbench, router: router).navigationTitle("Team Profiles")
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

/// Benches first, each with its sites beneath, then Team Profiles and Find Benches.
struct MainSidebar: View {
    let store: BenchStore
    let model: SidebarModel
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Benches") {
                if model.isEmpty {
                    Text(SidebarModel.emptyText).foregroundStyle(.secondary)
                }
                ForEach(model.benches) { row in
                    HStack(spacing: WindowMetrics.rowSpacing) {
                        Image(systemName: "circle.fill").font(.caption2).imageScale(.small)
                            .foregroundStyle(StatePill.color(for: row.state))
                            .environment(\.backgroundProminence, .standard)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing) {
                            Text(row.name)
                            if let hint = row.hint {
                                Text(hint).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if row.isBusy { ProgressView().controlSize(.mini) }
                    }
                    .help([row.path, row.guidance].compactMap { $0 }.joined(separator: "\n"))
                    .tag(SidebarItem.bench(row.path))
                    .contextMenu {
                        if let bench = store.benches.first(where: { $0.path == row.path }) {
                            BenchContextMenu(store: store, bench: bench)
                        }
                    }
                    ForEach(row.sites) { site in
                        HStack(spacing: 6) {
                            Image(systemName: site.isDefault ? "star.fill" : "globe").font(.caption2)
                                .foregroundStyle(site.isDefault ? Color.yellow : Color.secondary)
                                .environment(\.backgroundProminence, .standard)
                                .accessibilityLabel(site.isDefault ? "Default site" : "Site")
                            Text(site.name)
                        }
                        .font(.callout)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.leading, WindowMetrics.paneInset - 4)
                        .tag(SidebarItem.site(bench: row.path, name: site.name))
                            .help("Sites of \(row.name)")
                    }
                }
            }
            Section {
                Label("Team Profiles", systemImage: "person.2").tag(SidebarItem.profiles)
                Label("Find Benches", systemImage: "folder.badge.plus").tag(SidebarItem.discovery)
            }
        }
    }
}

/// The "+" pinned at the bottom of the sidebar.
struct SidebarFooter: View {
    @Bindable var router: WindowRouter
    let wizard: WizardRun

    var body: some View {
        HStack {
            Menu {
                Button("New Bench…", systemImage: "plus.square") {
                    wizard.reopen()
                    router.pane = .wizard
                }
                Button("Adopt Existing Bench…", systemImage: "arrow.down.doc") {
                    router.scanRequested = true
                    router.pane = .discovery
                }
                Button("Find Benches…", systemImage: "folder.badge.plus") { router.pane = .discovery }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Add a bench")
            .help("New Bench, Adopt Existing Bench, Find Benches")
            Spacer()
        }
        .padding(.horizontal, WindowMetrics.spacing).padding(.vertical, WindowMetrics.rowSpacing)
    }
}

/// A message for the whole window, for now only from a benchbar:// link.
struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        PaneBanner(symbol: "link", tint: .orange, title: "A BenchBar link did nothing", detail: text, dismiss: dismiss)
    }
}

/// The banner with the outcome of the last change, at the top of a pane.
struct ChangeResultBanner: View {
    let workbench: Workbench
    /// Only the outcome of a change made here: a bench's path, or the profiles scope.
    let scope: String

    var body: some View {
        if let result = workbench.result, result.scope == scope {
            PaneBanner(symbol: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                   tint: result.succeeded ? .green : .red,
                   title: result.succeeded ? "\(result.title): done" : "\(result.title): failed",
                   detail: result.error, dismiss: { workbench.result = nil })
        }
    }
}
