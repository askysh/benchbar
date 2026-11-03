import Foundation
import Network

/// The edge check on a browser's request before a single byte goes to the host.
nonisolated enum ForwarderGate {
    enum Verdict: Equatable {
        case needMore
        case relay(Data)
        case refuse(ForwarderPage, acceptsHTML: Bool)
    }

    static let maxHead = 32 * 1024

    /// `expectedHost` is `<name>:<port>`. Exactly one Host equal to it; Origin absent or the
    /// same origin; no cross-site or same-site Sec-Fetch-Site; no Upgrade (v1 has no
    /// WebSocket). The head goes on with `Connection: close`, so one local connection carries
    /// one request and every request passes this check: a keep-alive connection reused for a
    /// later cross-site request would otherwise skip it.
    static func check(_ buffer: Data, expectedHost: String) -> Verdict {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHead ? .refuse(.notAvailable, acceptsHTML: false) : .needMore
        }
        guard end.lowerBound <= maxHead, let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .refuse(.notAvailable, acceptsHTML: false)
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        var headers: [(name: String, value: String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { return .refuse(.notAvailable, acceptsHTML: false) }
            headers.append((line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        func values(_ name: String) -> [String] { headers.filter { $0.name == name }.map(\.value) }
        let acceptsHTML = values("accept").contains { $0.contains("text/html") }
        let refused = Verdict.refuse(.notAvailable, acceptsHTML: acceptsHTML)
        guard values("host") == [expectedHost] else { return refused }
        let origins = values("origin")
        guard origins.isEmpty || origins == ["http://\(expectedHost)"] else { return refused }
        if values("sec-fetch-site").contains(where: { ["cross-site", "same-site"].contains($0.lowercased()) }) { return refused }
        if !values("upgrade").isEmpty { return refused }

        let hopByHop: Set<String> = ["connection", "keep-alive", "proxy-connection"]
        var rewritten = requestLine + "\r\n"
        for line in lines {
            let name = line.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? ""
            if !hopByHop.contains(name) { rewritten += line + "\r\n" }
        }
        rewritten += "Connection: close\r\n\r\n"
        return .relay(Data(rewritten.utf8) + buffer[end.upperBound...])
    }
}

/// Why the upstream did not open.
nonisolated enum UpstreamFailure: Sendable, Equatable {
    case identityChanged
    case unreachable
}

/// A loopback listener (127.0.0.1 and ::1 only, R0-2) that relays each browser connection
/// to the host over its own pinned mTLS connection.
nonisolated final class ShareForwarder: @unchecked Sendable {
    static let idleLimit: TimeInterval = 15 * 60

    let localHost: String
    private(set) var port: UInt16
    private let hostLabel: String
    private let makeUpstream: @Sendable () -> (NWConnection, PeerCapture?)?
    private let pin: Data?
    private let queue = DispatchQueue(label: "benchbar.share.forwarder")
    private let lock = NSLock()
    private var listeners: [NWListener] = []
    private var active = 0
    private var lastActivity: Date
    private let now: @Sendable () -> Date
    /// Set by the health ping: what to show instead of relaying.
    private var override: ForwarderPage?

    /// `makeUpstream` returns a not-yet-started connection to the host, and the capture box
    /// its pinned TLS parameters write to (nil for a plain test upstream); nil when the
    /// client identity cannot be read.
    init(localHost: String, port: UInt16, hostLabel: String, pin: Data?, now: @escaping @Sendable () -> Date = Date.init,
         makeUpstream: @escaping @Sendable () -> (NWConnection, PeerCapture?)?) {
        self.localHost = localHost
        self.port = port
        self.hostLabel = hostLabel
        self.pin = pin
        self.now = now
        self.makeUpstream = makeUpstream
        lastActivity = now()
    }

    /// Each browser connection gets its own pinned mTLS connection to the host.
    static func pinnedUpstream(to endpoint: NWEndpoint, identity: any IdentityProviding, pin: Data) -> @Sendable () -> (NWConnection, PeerCapture?)? {
        {
            guard let secIdentity = try? identity.identity() else { return nil }
            let capture = PeerCapture()
            return (NWConnection(to: endpoint, using: PinnedTLS.parameters(identity: secIdentity, pin: .pinned(pin), capture: capture)), capture)
        }
    }

    var isRunning: Bool { lock.withLock { !listeners.isEmpty } }
    var expectedHost: String { "\(localHost):\(port)" }

    /// What Open hands the browser: the gateway signs the browser in as this Mac's seat.
    func signInURL(next: String = "/app") -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = localHost
        components.port = Int(port)
        components.path = "/_benchbar/signin"
        components.queryItems = [URLQueryItem(name: "next", value: next)]
        return components.url
    }

    func show(_ page: ForwarderPage?) {
        lock.withLock { override = page }
    }

    /// Binds both loopback addresses; a taken port (the free check is racy) moves to the next.
    func start(attempts: Int = 20) async throws {
        for _ in 0..<attempts {
            if await bind(port: port) { return }
            port = port >= UInt16(LocalShareName.portRange.upperBound) ? UInt16(LocalShareName.portRange.lowerBound) : port + 1
        }
        throw NWError.posix(.EADDRINUSE)
    }

    private func bind(port: UInt16) async -> Bool {
        var bound: [NWListener] = []
        for (address, version) in [("127.0.0.1", NWProtocolIP.Options.Version.v4), ("::1", .v6)] {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!)
            (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = version
            // Without reuse the second address of the same port fails with EADDRINUSE. A port
            // another process holds without reuse still refuses the bind.
            parameters.allowLocalEndpointReuse = true
            guard let listener = try? NWListener(using: parameters), await ready(listener) else {
                bound.forEach { $0.cancel() }
                return false
            }
            bound.append(listener)
        }
        lock.withLock {
            listeners = bound
            lastActivity = now()
        }
        return true
    }

    private func ready(_ listener: NWListener) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume(returning: true) }
                case .failed, .cancelled, .waiting: if once.claim() { listener.cancel(); continuation.resume(returning: false) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        let stopping = lock.withLock {
            defer { listeners = [] }
            return listeners
        }
        stopping.forEach { $0.cancel() }
    }

    /// Called by a timer: stops after 15 minutes without a connection.
    @discardableResult
    func stopIfIdle() -> Bool {
        let idle = lock.withLock { active == 0 && now().timeIntervalSince(lastActivity) >= Self.idleLimit }
        if idle { stop() }
        return idle
    }

    private func touch(_ delta: Int) {
        lock.withLock {
            active += delta
            lastActivity = now()
        }
    }

    private func accept(_ local: NWConnection) {
        touch(1)
        local.start(queue: queue)
        readHead(local, buffer: Data())
    }

    private func finish(_ local: NWConnection, upstream: NWConnection? = nil) {
        local.cancel()
        upstream?.cancel()
        touch(-1)
    }

    private func readHead(_ local: NWConnection, buffer: Data) {
        local.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return local.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch ForwarderGate.check(buffer, expectedHost: self.expectedHost) {
            case .needMore:
                if isComplete || error != nil { return self.finish(local) }
                self.readHead(local, buffer: buffer)
            case .refuse(let page, let html):
                self.respond(local, page, acceptsHTML: html)
            case .relay(let head):
                if let page = self.lock.withLock({ self.override }) {
                    return self.respond(local, page, acceptsHTML: buffer.range(of: Data("text/html".utf8)) != nil)
                }
                self.connectUpstream(local, head: head, acceptsHTML: buffer.range(of: Data("text/html".utf8)) != nil)
            }
        }
    }

    private func respond(_ local: NWConnection, _ page: ForwarderPage, acceptsHTML: Bool) {
        local.send(content: page.response(acceptsHTML: acceptsHTML), isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.finish(local)
        })
    }

    private func connectUpstream(_ local: NWConnection, head: Data, acceptsHTML: Bool) {
        guard let (upstream, capture) = makeUpstream() else { return respond(local, .notAvailable, acceptsHTML: acceptsHTML) }
        let once = ResumeOnce()
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard once.claim() else { return }
                let ended = ResumeOnce()
                let end: @Sendable () -> Void = { if ended.claim() { self.finish(local, upstream: upstream) } }
                upstream.send(content: head, completion: .contentProcessed { error in
                    if error != nil { return end() }
                    self.pump(from: local, to: upstream, end: end, endOnClose: false)
                    self.pump(from: upstream, to: local, end: end, endOnClose: true)
                })
            case .waiting, .failed:
                guard once.claim() else { return }
                upstream.cancel()
                let seen = capture?.spkiHash
                let changed = self.pin != nil && seen != nil && seen != self.pin
                let page: ForwarderPage = changed ? .identityChanged(host: self.hostLabel) : .hostOffline(host: self.hostLabel, lastSeen: "a moment ago")
                self.respond(local, page, acceptsHTML: acceptsHTML)
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    /// Back-pressure: the next receive waits until the previous send was processed. An error
    /// on either side ends both. `Connection: close` went upstream, so the upstream closing
    /// is the end of the exchange; the browser half-closing only half-closes upstream.
    private func pump(from source: NWConnection, to sink: NWConnection, end: @escaping @Sendable () -> Void, endOnClose: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return end() }
            if error != nil { return end() }
            let closeSink: @Sendable () -> Void = {
                sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    if endOnClose { end() }
                })
            }
            guard let data, !data.isEmpty else {
                return isComplete ? closeSink() : self.pump(from: source, to: sink, end: end, endOnClose: endOnClose)
            }
            sink.send(content: data, completion: .contentProcessed { sendError in
                if sendError != nil { return end() }
                if isComplete { return closeSink() }
                self.pump(from: source, to: sink, end: end, endOnClose: endOnClose)
            })
        }
    }
}
