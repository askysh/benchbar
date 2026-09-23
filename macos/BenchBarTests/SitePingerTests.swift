import Foundation
import Network
import Testing
@testable import BenchBar

@Suite("Site pinger")
struct SitePingerTests {
    @Test func parsesTheStatusLine() {
        #expect(SitePinger.statusCode(of: Data("HTTP/1.1 200 OK\r\n".utf8)) == 200)
        #expect(SitePinger.statusCode(of: Data("HTTP/1.0 404 Not Found\r\n".utf8)) == 404)
        #expect(SitePinger.statusCode(of: Data("garbage".utf8)) == nil)
    }

    @Test func closedPortIsNil() async {
        // port 9 (discard) is never open on a Mac
        let code = await SitePinger.ping(site: "macdev", port: 9, timeout: .seconds(2))
        #expect(code == nil)
    }

    @Test func talksHTTPWithTheSiteAsHost() async throws {
        let server = try TinyHTTPServer()
        let code = await SitePinger.ping(site: "macdev", port: Int(server.port), timeout: .seconds(3))
        #expect(code == 200)
        #expect(server.lastRequest.contains("GET /api/method/ping HTTP/1.1"))
        #expect(server.lastRequest.contains("Host: macdev"))
        server.stop()
    }
}

/// Answers every connection with "200 OK" and remembers the request.
nonisolated final class TinyHTTPServer: @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var request = ""
    }
    private let listener: NWListener
    private let box = Box()
    let port: UInt16

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        let box = self.box
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                box.lock.withLock { box.request = String(decoding: data ?? Data(), as: UTF8.self) }
                let body = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8)
                connection.send(content: body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 2)
        port = listener.port?.rawValue ?? 0
    }

    var lastRequest: String { box.lock.withLock { box.request } }
    func stop() { listener.cancel() }
}
