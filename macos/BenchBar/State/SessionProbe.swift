import Foundation
import Network

/// Asks a site who a session id belongs to: `GET /api/method/frappe.auth.get_logged_user`
/// with the id as the `sid` cookie. The answer is the user while the session
/// is alive, and Guest (or an error) once it is not.
///
/// Like SitePinger it speaks plain HTTP to 127.0.0.1 with the site in the Host
/// header: the site needs no hosts line, and App Transport Security (which
/// blocks http to a hostname such as macdev) is never asked.
nonisolated enum SessionProbe {
    /// The user the session belongs to, or nil when nothing answered in time.
    static func loggedUser(sessionID: String, site: String, port: Int, timeout: Duration = .seconds(2)) async -> String? {
        guard let request = request(site: site, sessionID: sessionID),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        let collector = Collector()

        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                collector.set(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                            if error != nil { collector.finish() }
                        })
                        receive(on: connection, into: collector)
                    case .failed, .waiting:
                        collector.finish()
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) {
                    collector.finish()
                }
            }
        } onCancel: {
            collector.finish()
        }
        connection.cancel()
        return user(inResponse: response)
    }

    private static func receive(on connection: NWConnection, into collector: Collector) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            if let data { collector.append(data) }
            if isComplete || error != nil { collector.finish() } else { receive(on: connection, into: collector) }
        }
    }

    /// nil for an id that is not a plain token: it goes into a header, so a
    /// line break in it would be a second header.
    static func request(site: String, sessionID: String) -> String? {
        let token = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        guard !sessionID.isEmpty, sessionID.unicodeScalars.allSatisfy(token.contains),
              !site.contains(where: { $0.isNewline || $0 == " " }) else { return nil }
        return "GET /api/method/frappe.auth.get_logged_user HTTP/1.1\r\nHost: \(site)\r\nCookie: sid=\(sessionID)\r\n"
            + "Accept: application/json\r\nConnection: close\r\nUser-Agent: BenchBar\r\n\r\n"
    }

    /// `{"message":"user"}` out of a 200 response. The body is cut at its
    /// braces, so a chunked response parses too.
    static func user(inResponse data: Data) -> String? {
        guard SitePinger.statusCode(of: data) == 200 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return nil }
        return (try? JSONDecoder().decode(Answer.self, from: Data(text[open...close].utf8)))?.message
    }

    private nonisolated struct Answer: Decodable { var message: String }

    /// Gathers the response and resumes the continuation exactly once.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Never>?
        private var data = Data()
        private var done = false

        func set(_ continuation: CheckedContinuation<Data, Never>) {
            lock.withLock {
                if done { continuation.resume(returning: data) } else { self.continuation = continuation }
            }
        }

        func append(_ more: Data) {
            lock.withLock { if !done { data.append(more) } }
        }

        func finish() {
            let pending: (CheckedContinuation<Data, Never>, Data)? = lock.withLock {
                guard !done else { return nil }
                done = true
                defer { continuation = nil }
                return continuation.map { ($0, data) }
            }
            if let (continuation, collected) = pending { continuation.resume(returning: collected) }
        }
    }
}
