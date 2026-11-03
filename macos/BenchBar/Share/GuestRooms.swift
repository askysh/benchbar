import Foundation
import Network

/// What a Bonjour TXT record may show. Display only: nothing here is used for trust,
/// pinning or connecting.
nonisolated struct RoomDisplay: Equatable, Sendable {
    var label: String
    var site: String
    var protocolV: Int?

    var needsUpdate: Bool { protocolV != CPace.protocolVersion }
}

nonisolated enum TXTSanitizer {
    static let maxLength = 40

    /// Keeps only `v`, `label` and `site`; strips control, bidi and zero-width characters,
    /// collapses whitespace and caps the length.
    static func display(txt: [String: String]) -> RoomDisplay {
        RoomDisplay(label: clean(txt["label"] ?? ""), site: clean(txt["site"] ?? ""), protocolV: txt["v"].flatMap { Int($0) })
    }

    static func clean(_ text: String) -> String {
        let unsafe: (Unicode.Scalar) -> Bool = { scalar in
            let value = scalar.value
            return value < 0x20 || (0x7f...0x9f).contains(value) || (0x200b...0x200f).contains(value) || (0x202a...0x202e).contains(value)
                || (0x2060...0x2064).contains(value) || (0x2066...0x2069).contains(value) || value == 0xfeff || value == 0x2028 || value == 0x2029
        }
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.map { unsafe($0) ? " " : $0 }))
        let collapsed = kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(maxLength))
    }
}

nonisolated struct DiscoveredRoom: Identifiable, Equatable, Sendable {
    /// The Bonjour service name.
    var id: String
    var endpoint: NWEndpoint
    var display: RoomDisplay
}

/// A room this Mac joined. No secrets: the code is never stored (J12), the key lives in the
/// Keychain, and the host pin is public.
nonisolated struct SavedRoom: Codable, Identifiable, Equatable, Sendable {
    var id: String { hostFingerprint }
    var hostFingerprint: String
    var deviceId: String
    var room: String
    var host: String
    var site: String
    var serviceName: String
    var lastHost: String
    var port: UInt16
    var localPort: UInt16?
    var joinedAt: Date

    var hostPin: Data? { Fingerprint.raw(fingerprint: hostFingerprint) }
}

/// Saved rooms in UserDefaults (`shareGuestRooms`), JSON.
nonisolated struct SavedRoomsStore {
    static let key = "shareGuestRooms"
    let defaults: UserDefaults

    func load() -> [SavedRoom] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([SavedRoom].self, from: data)) ?? []
    }

    /// A room from the same host replaces the old row: devices are per room (R3.5).
    func save(_ room: SavedRoom) {
        var rooms = load().filter { $0.hostFingerprint != room.hostFingerprint }
        rooms.append(room)
        write(rooms)
    }

    func forget(_ room: SavedRoom) {
        write(load().filter { $0.hostFingerprint != room.hostFingerprint })
    }

    func forgetAll() {
        defaults.removeObject(forKey: Self.key)
    }

    private func write(_ rooms: [SavedRoom]) {
        if let data = try? JSONEncoder().encode(rooms) { defaults.set(data, forKey: Self.key) }
    }
}

/// The Bonjour browser behind the pane, injectable for tests.
nonisolated protocol RoomBrowsing: AnyObject, Sendable {
    func start(onChange: @escaping @Sendable ([DiscoveredRoom]) -> Void, onDenied: @escaping @Sendable () -> Void)
    func stop()
}

/// `_benchbar-share._tcp` with TXT. It only runs while the pane is visible. A service this
/// Mac advertises itself is hidden by its name.
nonisolated final class LanRoomBrowser: RoomBrowsing, @unchecked Sendable {
    static let serviceType = "_benchbar-share._tcp"
    private var browser: NWBrowser?
    private let ownServiceNames: @Sendable () -> Set<String>

    init(ownServiceNames: @escaping @Sendable () -> Set<String> = { [] }) {
        self.ownServiceNames = ownServiceNames
    }

    func start(onChange: @escaping @Sendable ([DiscoveredRoom]) -> Void, onDenied: @escaping @Sendable () -> Void) {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        let own = ownServiceNames
        browser.browseResultsChangedHandler = { @Sendable results, _ in
            onChange(Self.rooms(from: results, hiding: own()))
        }
        browser.stateUpdateHandler = { @Sendable state in
            if case .waiting(let error) = state, case .dns(let code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ { onDenied() }
        }
        browser.start(queue: DispatchQueue(label: "benchbar.share.browser"))
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    static func rooms(from results: Set<NWBrowser.Result>, hiding own: Set<String>) -> [DiscoveredRoom] {
        var byName: [String: DiscoveredRoom] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint, !own.contains(name) else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata { txt = record.dictionary }
            byName[name] = DiscoveredRoom(id: name, endpoint: result.endpoint, display: TXTSanitizer.display(txt: txt))
        }
        return byName.values.sorted { $0.display.label.localizedCaseInsensitiveCompare($1.display.label) == .orderedAscending }
    }
}
