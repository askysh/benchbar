import AppKit
import Network
import Observation

/// One ShareStore per bench, made on first use, plus what reruns the checks
/// (wake and network changes). The app delegate attaches the bench store
/// once; views reach it through `ShareCenter.shared`.
///
/// Nothing runs at launch for a person who never shares: no store, no
/// `share status` call, no network monitor, no wake observer. A store is made
/// when the Sharing tab first shows, or at launch for a bench whose share was
/// on at the last quit (`restoreActive`); the monitor and the observer start
/// with the first store.
@Observable
final class ShareCenter {
    static let shared = ShareCenter()
    nonisolated static let activeKey = "shareActiveBenches"

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private(set) var stores: [String: ShareStore] = [:]
    @ObservationIgnored private weak var benchStore: BenchStore?
    @ObservationIgnored var onEvent: ((ShareStore, ShareEvent) -> Void)?
    /// The menu bar's sharing state, told on every change.
    @ObservationIgnored var onIconChange: ((HostAmbient.IconState) -> Void)?
    @ObservationIgnored private var icon: HostAmbient.IconState = .off
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var sawFirstPath = false

    /// Remembers the bench store; starts nothing.
    func attach(_ store: BenchStore) {
        benchStore = store
    }

    /// The wake observer and the network monitor are running (a store exists).
    var isWatching: Bool { pathMonitor != nil }

    /// Benches whose share was on or starting at the last quit.
    var savedActive: Set<String> { Set(defaults.stringArray(forKey: Self.activeKey) ?? []) }

    /// At launch: stores only for benches that were sharing when the app quit.
    func restoreActive(among benches: [String]) {
        let saved = savedActive
        for bench in benches where saved.contains(bench) { _ = store(for: bench) }
    }

    private func startWatching() {
        guard pathMonitor == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.networkChanged() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.pathUpdated() }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    /// The bench's store, nil without a CLI.
    func store(for bench: String) -> ShareStore? {
        if let made = stores[bench] { return made }
        guard let client = benchStore?.cliClient else { return nil }
        let made = ShareStore(bench: bench, client: client)
        made.onEvent = { [weak self, weak made] event in
            guard let made else { return }
            self?.onEvent?(made, event)
        }
        made.onStatus = { [weak self] in self?.statusChanged() }
        // errors stay in the store (`lastError`): the Sharing tab and the popover row show
        // them, the bench's red banner does not
        stores[bench] = made
        startWatching()
        // one read on first sight, so a share that is already on is found
        made.ensurePolling()
        return made
    }

    /// The Sharing tab is hidden only when the CLI has no share command.
    func showsTab(for bench: String) -> Bool {
        stores[bench]?.availability != .unavailable
    }

    /// A share setup or teardown is running on some bench (the quit alert).
    var setupOrTeardownRunning: Bool { stores.values.contains(where: \.stopsHalfwayIfQuit) }

    /// Benches that are shared with at least one person in the room (the quit alert).
    var benchesWithGuests: [ShareStore] { stores.values.filter { $0.isSharing && ($0.status?.people ?? 0) > 0 }.sorted { $0.bench < $1.bench } }

    var sharingStores: [ShareStore] { stores.values.filter(\.isSharing).sorted { $0.bench < $1.bench } }

    private func statusChanged() {
        let live = stores.values.filter { $0.status?.state == .on || $0.status?.state == .starting }.map(\.bench)
        // not while a first read is pending: an unread store would forget a share that is on
        if stores.values.allSatisfy({ $0.status != nil || $0.availability == .unavailable }) {
            defaults.set(live.sorted(), forKey: Self.activeKey)
        }
        let next = HostAmbient.icon(stores.values.compactMap(\.status))
        guard next != icon else { return }
        icon = next
        onIconChange?(next)
    }

    /// The first update is the current path, not a change.
    private func pathUpdated() {
        guard sawFirstPath else { sawFirstPath = true; return }
        networkChanged()
    }

    private func networkChanged() {
        for store in stores.values where store.isSharing || store.tabVisible { store.networkChanged() }
    }
}
