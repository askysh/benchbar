import AppKit
import Network
import Observation

/// One ShareStore per bench, made on first use, plus what reruns the checks
/// (wake and network changes). The app delegate attaches the bench store
/// once; views reach it through `ShareCenter.shared`.
@Observable
final class ShareCenter {
    static let shared = ShareCenter()

    private(set) var stores: [String: ShareStore] = [:]
    @ObservationIgnored private weak var benchStore: BenchStore?
    @ObservationIgnored var onEvent: ((ShareStore, ShareEvent) -> Void)?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var sawFirstPath = false

    func attach(_ store: BenchStore) {
        benchStore = store
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
        made.onError = { [weak self] text in
            self?.benchStore?.benches.first { $0.path == bench }?.lastError = text
        }
        stores[bench] = made
        // one read on first sight, so a share that is already on is found
        made.ensurePolling()
        return made
    }

    /// The Sharing tab is hidden only when the CLI has no share command.
    func showsTab(for bench: String) -> Bool {
        stores[bench]?.availability != .unavailable
    }

    var sharingStores: [ShareStore] { stores.values.filter(\.isSharing).sorted { $0.bench < $1.bench } }

    /// The first update is the current path, not a change.
    private func pathUpdated() {
        guard sawFirstPath else { sawFirstPath = true; return }
        networkChanged()
    }

    private func networkChanged() {
        for store in stores.values where store.isSharing || store.tabVisible { store.networkChanged() }
    }
}
