import Foundation
import Network
import Testing
@testable import BenchBar

/// Sends raw bytes to a loopback port and returns everything until the peer closes.
nonisolated func rawExchange(host: String = "127.0.0.1", port: UInt16, _ request: String) async -> String {
    let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let queue = DispatchQueue(label: "raw-exchange")
    return await withCheckedContinuation { continuation in
        let once = ResumeOnce()
        let box = DataBox()
        let done: @Sendable () -> Void = {
            guard once.claim() else { return }
            connection.cancel()
            continuation.resume(returning: String(decoding: box.data, as: UTF8.self))
        }
        @Sendable func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data { box.append(data) }
                if isComplete || error != nil { return done() }
                read()
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in read() })
            case .failed, .waiting: done()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { done() }
    }
}

nonisolated final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    var data: Data { lock.withLock { _data } }
    func append(_ more: Data) { lock.withLock { _data.append(more) } }
}

/// A plain TCP stand-in for the host that records what arrives and answers once.
nonisolated final class FakeUpstream: @unchecked Sendable {
    let listener: NWListener
    let received = DataBox()
    private let lock = NSLock()
    private var _connections = 0
    var connections: Int { lock.withLock { _connections } }

    init() async throws {
        listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "fake-upstream")
        listener.newConnectionHandler = { [received] connection in
            self.lock.withLock { self._connections += 1 }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let data { received.append(data) }
                let body = "upstream-ok"
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)".utf8),
                                isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { if case .ready = $0, once.claim() { continuation.resume() } }
            listener.start(queue: queue)
        }
    }

    var port: UInt16 { listener.port!.rawValue }
}

@Suite struct ForwarderGateTests {
    private let host = "priya-1a2b3c4d.localhost:41234"

    @Test func aSameOriginRequestIsRelayedWithConnectionClose() {
        let request = "GET /app HTTP/1.1\r\nHost: \(host)\r\nConnection: keep-alive\r\nKeep-Alive: timeout=5\r\nOrigin: http://\(host)\r\nSec-Fetch-Site: same-origin\r\n\r\nBODY"
        guard case .relay(let head) = ForwarderGate.check(Data(request.utf8), expectedHost: host) else {
            Issue.record("expected relay")
            return
        }
        let text = String(decoding: head, as: UTF8.self)
        #expect(text.hasPrefix("GET /app HTTP/1.1\r\nHost: \(host)\r\n"))
        #expect(!text.lowercased().contains("keep-alive"))
        #expect(text.hasSuffix("Connection: close\r\n\r\nBODY"))
    }

    @Test(arguments: [
        "Host: evil.localhost:41234\r\n",
        "Host: priya-1a2b3c4d.localhost:41235\r\n",
        "Host: priya-1a2b3c4d.localhost:41234\r\nHost: priya-1a2b3c4d.localhost:41234\r\n",
        "",
        "Host: priya-1a2b3c4d.localhost:41234\r\nOrigin: http://evil.example\r\n",
        "Host: priya-1a2b3c4d.localhost:41234\r\nOrigin: null\r\n",
        "Host: priya-1a2b3c4d.localhost:41234\r\nSec-Fetch-Site: cross-site\r\n",
        "Host: priya-1a2b3c4d.localhost:41234\r\nSec-Fetch-Site: same-site\r\n",
        "Host: priya-1a2b3c4d.localhost:41234\r\nUpgrade: websocket\r\n",
    ])
    func everythingElseGetsTheNotAvailablePage(headers: String) {
        let request = "GET /app HTTP/1.1\r\n\(headers)Accept: text/html\r\n\r\n"
        #expect(ForwarderGate.check(Data(request.utf8), expectedHost: host) == .refuse(.notAvailable, acceptsHTML: true))
    }

    @Test func anIncompleteHeadWaitsAndAnOversizeOneIsRefused() {
        #expect(ForwarderGate.check(Data("GET / HTTP/1.1\r\nHost: x".utf8), expectedHost: host) == .needMore)
        #expect(ForwarderGate.check(Data(repeating: 0x41, count: ForwarderGate.maxHead + 1), expectedHost: host) == .refuse(.notAvailable, acceptsHTML: false))
    }
}

@Suite(.serialized) struct ShareForwarderTests {
    private func forwarder(to upstream: FakeUpstream, now: @escaping @Sendable () -> Date = Date.init) -> ShareForwarder {
        let port = LocalShareName.port(for: Data([UInt8.random(in: 0...255), UInt8.random(in: 0...255)]), isFree: { _ in true })!
        return ShareForwarder(localHost: "priya-1a2b3c4d.localhost", port: port, hostLabel: "Priya", pin: nil, now: now) {
            (NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: upstream.port)!, using: .tcp), nil)
        }
    }

    @Test func relaysBothWaysOnBothLoopbacksWithOneUpstreamPerConnection() async throws {
        let upstream = try await FakeUpstream()
        let forwarder = forwarder(to: upstream)
        try await forwarder.start()
        defer { forwarder.stop() }
        let request = "GET /app HTTP/1.1\r\nHost: \(forwarder.expectedHost)\r\n\r\n"
        let first = await rawExchange(port: forwarder.port, request)
        let second = await rawExchange(host: "::1", port: forwarder.port, request)
        #expect(first.hasSuffix("upstream-ok"))
        #expect(second.hasSuffix("upstream-ok"))
        #expect(upstream.connections == 2)
        #expect(String(decoding: upstream.received.data, as: UTF8.self).contains("Connection: close"))
    }

    @Test func aWrongHostNeverReachesTheHost() async throws {
        let upstream = try await FakeUpstream()
        let forwarder = forwarder(to: upstream)
        try await forwarder.start()
        defer { forwarder.stop() }
        let reply = await rawExchange(port: forwarder.port, "GET /app HTTP/1.1\r\nHost: evil.localhost:\(forwarder.port)\r\nAccept: text/html\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 403"))
        #expect(reply.contains("This page isn&#39;t available through BenchBar."))
        #expect(upstream.connections == 0)
    }

    @Test func listensOnLoopbackOnly() async throws {
        let upstream = try await FakeUpstream()
        let forwarder = forwarder(to: upstream)
        try await forwarder.start()
        defer { forwarder.stop() }
        let lan = Host.current().addresses.first { $0.contains(".") && $0 != "127.0.0.1" && !$0.hasPrefix("169.254") }
        if let lan {
            let reply = await rawExchange(host: lan, port: forwarder.port, "GET /app HTTP/1.1\r\nHost: \(forwarder.expectedHost)\r\n\r\n")
            #expect(reply.isEmpty)
        }
    }

    @Test func aTakenPortMovesToTheNext() async throws {
        let upstream = try await FakeUpstream()
        let blocker = try NWListener(using: .tcp, on: .any)
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            blocker.newConnectionHandler = { $0.cancel() }
            blocker.stateUpdateHandler = { if case .ready = $0, once.claim() { continuation.resume() } }
            blocker.start(queue: .global())
        }
        defer { blocker.cancel() }
        let taken = try #require(blocker.port?.rawValue)
        let forwarder = ShareForwarder(localHost: "x-00000000.localhost", port: taken, hostLabel: "X", pin: nil) {
            (NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: upstream.port)!, using: .tcp), nil)
        }
        try await forwarder.start()
        defer { forwarder.stop() }
        #expect(forwarder.port != taken)
    }

    @Test func stopsAfterFifteenIdleMinutes() async throws {
        let upstream = try await FakeUpstream()
        let clock = DateBox(Date(timeIntervalSince1970: 1_000_000))
        let forwarder = forwarder(to: upstream, now: { clock.value })
        try await forwarder.start()
        #expect(!forwarder.stopIfIdle())
        clock.value = clock.value.addingTimeInterval(14 * 60)
        #expect(!forwarder.stopIfIdle())
        clock.value = clock.value.addingTimeInterval(61)
        #expect(forwarder.stopIfIdle())
        #expect(!forwarder.isRunning)
    }

    @Test func anOverridePageIsServedInsteadOfRelaying() async throws {
        let upstream = try await FakeUpstream()
        let forwarder = forwarder(to: upstream)
        try await forwarder.start()
        defer { forwarder.stop() }
        forwarder.show(.removed(host: "Priya", askAgain: "benchbar://share/0011223344556677/app"))
        let reply = await rawExchange(port: forwarder.port, "GET /app HTTP/1.1\r\nHost: \(forwarder.expectedHost)\r\nAccept: text/html\r\n\r\n")
        #expect(reply.contains("Priya removed you from this room."))
        #expect(upstream.connections == 0)
    }
}

nonisolated final class DateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date
    init(_ value: Date) { _value = value }
    var value: Date {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@Suite struct ForwarderPagesTests {
    @Test(arguments: [
        (ForwarderPage.ended(host: "<b>Priya</b>"), "&lt;b&gt;Priya&lt;/b&gt; ended the room."),
        (.removed(host: "<b>Priya</b>", askAgain: "benchbar://share/0011223344556677/app"), "&lt;b&gt;Priya&lt;/b&gt; removed you from this room."),
        (.hostOffline(host: "<b>Priya</b>", lastSeen: "10:42"), "&lt;b&gt;Priya&lt;/b&gt; isn&#39;t sharing right now (last seen 10:42)."),
        (.identityChanged(host: "<b>Priya</b>"), "&lt;b&gt;Priya&lt;/b&gt;&#39;s Mac looks different from the one you joined."),
        (.notAvailable, "This page isn&#39;t available through BenchBar."),
    ])
    func eachPageHasItsCopyEscapedAndNoScript(page: ForwarderPage, copy: String) {
        let html = String(decoding: page.response(acceptsHTML: true), as: UTF8.self)
        #expect(html.contains(copy))
        #expect(!html.lowercased().contains("<script"))
        #expect(!html.contains("http://") && !html.contains("https://"))
        #expect(!html.contains("<b>"))
        let text = String(decoding: page.response(acceptsHTML: false), as: UTF8.self)
        #expect(text.contains("Content-Type: text/plain"))
        #expect(text.hasSuffix(page.message + "\n"))
    }

    @Test func theRemovedPageLinksOnlyToBenchbarShare() {
        let html = String(decoding: ForwarderPage.removed(host: "P", askAgain: "javascript:alert(1)").response(acceptsHTML: true), as: UTF8.self)
        #expect(!html.contains("Ask again"))
        let good = String(decoding: ForwarderPage.removed(host: "P", askAgain: "benchbar://share/0011223344556677/app").response(acceptsHTML: true), as: UTF8.self)
        #expect(good.contains("<a href=\"benchbar://share/0011223344556677/app\">Ask again</a>"))
    }
}

@Suite struct LocalShareNameTests {
    @Test(arguments: [("Priya's Mac", "priyas-mac"), ("  Dev   Room  ", "dev-room"), ("Café Ünïcode", "cafe-unicode"), ("", "room"),
                      ("日本", "room"), ("-lead", "lead"), (String(repeating: "a", count: 60), String(repeating: "a", count: 40))])
    func slugIsLowerCaseAndBounded(label: String, slug: String) {
        let made = LocalShareName.slug(label: label)
        #expect(made == slug)
        #expect((1...40).contains(made.count))
        #expect(!made.hasPrefix("-"))
        #expect(made.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
    }

    @Test func theSuffixIsStablePerInstallAndDiffersBetweenInstalls() throws {
        let one = try #require(UserDefaults(suiteName: "share-name-\(UUID().uuidString)"))
        let two = try #require(UserDefaults(suiteName: "share-name-\(UUID().uuidString)"))
        let suffix = LocalShareName.installSuffix(defaults: one)
        #expect(suffix.count == 8)
        #expect(LocalShareName.installSuffix(defaults: one) == suffix)
        #expect(LocalShareName.installSuffix(defaults: two) != suffix)
        let pin = Data(repeating: 7, count: 32)
        #expect(LocalShareName.host(label: "Priya", suffix: suffix, hostPin: pin) != LocalShareName.host(label: "Priya", suffix: LocalShareName.installSuffix(defaults: two), hostPin: pin))
    }

    @Test func roomsWithOneLabelButDifferentHostsNeverShareACookieJar() {
        let hostA = Data(repeating: 0xA1, count: 32), hostB = Data(repeating: 0xB2, count: 32)
        let nameA = LocalShareName.host(label: "Akash's room", suffix: "1a2b3c4d", hostPin: hostA)
        #expect(nameA != LocalShareName.host(label: "Akash's room", suffix: "1a2b3c4d", hostPin: hostB))
        #expect(nameA == LocalShareName.host(label: "Akash's room", suffix: "1a2b3c4d", hostPin: hostA))
        #expect(nameA.hasPrefix("akashs-room-") && nameA.hasSuffix(".localhost"))
        let longest = LocalShareName.host(label: String(repeating: "a", count: 60), suffix: "1a2b3c4d", hostPin: hostA)
        #expect(longest.dropLast(".localhost".count).count <= 63)
    }

    @Test func portIsDeterministicAndSkipsTakenPorts() {
        let pin = Data([0x12, 0x34] + Array(repeating: 0, count: 30))
        let first = LocalShareName.port(for: pin, isFree: { _ in true })
        #expect(first == LocalShareName.port(for: pin, isFree: { _ in true }))
        #expect(first.map { LocalShareName.portRange.contains(Int($0)) } == true)
        #expect(LocalShareName.port(for: pin, isFree: { $0 != first }) == first.map { $0 + 1 })
        #expect(LocalShareName.port(for: pin, isFree: { _ in false }) == nil)
    }
}

@Suite struct ShareDeepLinkTests {
    @Test func aSavedRoomPathParses() throws {
        let target = try #require(ShareDeepLink.parse(URL(string: "benchbar://share/0011223344556677/app/sales-order/SO-1")!))
        #expect(target == .init(fp16: "0011223344556677", path: "/app/sales-order/SO-1"))
    }

    @Test(arguments: ["benchbar://share/0011223344556677//evil", "benchbar://share/0011223344556677/api/method/x",
                      "benchbar://share/0011223344556677/app/%2e%2e/x", "benchbar://share/0011223344556677/app/../api",
                      "benchbar://share/001122334455667/app", "benchbar://share/0011223344556677/app?x=1",
                      "benchbar://share/0011223344556677/app%2Fx", "benchbar://other/0011223344556677/app"])
    func unsafeOrForeignLinksAreRefused(link: String) {
        #expect(URL(string: link).flatMap(ShareDeepLink.parse) == nil)
    }

    /// Every path the gateway refuses is refused here too.
    @Test func theGatewayPathVectorsAreNeverLooser() throws {
        let paths = try ShareRepo.vectors()["paths"] as? [[String: Any]] ?? []
        #expect(!paths.isEmpty)
        for vector in paths {
            let raw = vector["raw"] as? String ?? ""
            let ok = vector["ok"] as? Bool ?? false
            if !ok { #expect(!ShareDeepLink.isSafeAppPath(raw), "\(raw)") }
            if ok, let path = vector["path"] as? String, (raw == "/app" || raw.hasPrefix("/app/")), (vector["search"] as? String ?? "").isEmpty, !path.contains("%") {
                #expect(ShareDeepLink.isSafeAppPath(raw), "\(raw)")
            }
        }
    }
}
