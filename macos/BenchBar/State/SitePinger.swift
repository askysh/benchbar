import Foundation
import Network

/// One HTTP request to `http://127.0.0.1:<port>/api/method/ping` with the
/// site in the Host header, exactly like the CLI's own ping. Frappe picks
/// the site from the Host header, and 127.0.0.1 works even without an
/// /etc/hosts entry.
///
/// URLSession does not let us set the Host header, so this speaks plain
/// HTTP/1.1 over a Network framework TCP connection.
nonisolated enum SitePinger {
    /// Returns the HTTP status code, or nil when nothing answered in time.
    static func ping(site: String, port: Int, timeout: Duration = .seconds(3)) async -> Int? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        let request = "GET /api/method/ping HTTP/1.1\r\nHost: \(site)\r\nConnection: close\r\nUser-Agent: BenchBar\r\n\r\n"
        let box = ResultBox()

        let code = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
                box.set(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                            if error != nil { box.finish(nil) }
                        })
                        connection.receive(minimumIncompleteLength: 12, maximumLength: 512) { data, _, _, _ in
                            box.finish(data.flatMap(Self.statusCode(of:)))
                        }
                    case .failed, .waiting:
                        box.finish(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .utility))
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) {
                    box.finish(nil)
                }
            }
        } onCancel: {
            box.finish(nil)
        }
        connection.cancel()
        return code
    }

    /// "HTTP/1.1 200 OK" to 200.
    static func statusCode(of data: Data) -> Int? {
        let head = String(decoding: data.prefix(64), as: UTF8.self)
        let parts = head.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/") else { return nil }
        return Int(parts[1])
    }

    /// Resumes the continuation exactly once, whichever callback comes first.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Int?, Never>?
        private var done = false

        func set(_ continuation: CheckedContinuation<Int?, Never>) {
            lock.withLock {
                if done { continuation.resume(returning: nil) } else { self.continuation = continuation }
            }
        }

        func finish(_ value: Int?) {
            let pending: CheckedContinuation<Int?, Never>? = lock.withLock {
                guard !done else { return nil }
                done = true
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }
}
