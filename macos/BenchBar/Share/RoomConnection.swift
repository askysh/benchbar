import Foundation
import Network
import Security

nonisolated struct RoomResponse: Sendable, Equatable {
    var status: Int
    var headers: [String: String]
    var body: Data

    func json<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: body)
    }

    /// The gateway's refusals carry `status` (or `error`) in the body; the HTTP code alone is ambiguous.
    var reason: String? {
        struct Reason: Decodable { var status: String?; var error: String? }
        guard let decoded = json(Reason.self) else { return nil }
        return decoded.status ?? decoded.error
    }
}

nonisolated enum RoomConnectionError: Error, Equatable, Sendable {
    case unreachable
    case localNetworkDenied
    case identityChanged
    case closed
    case malformed
    case timedOut
}

/// One request at a time on one keep-alive TLS connection: what a join needs, since Ta is
/// bound to the exporter and server SPKI of the connection finish goes out on (J11, J16).
nonisolated protocol RoomTransport: AnyObject, Sendable {
    func send(_ method: String, _ path: String, body: Data?) async throws(RoomConnectionError) -> RoomResponse
    /// Fh: the server SPKI hash this connection saw in its handshake.
    var serverSPKIHash: Data? { get }
    var exporter: Data? { get }
    /// The resolved address, kept so a saved room reconnects without Bonjour first.
    var remoteEndpoint: NWEndpoint? { get }
    func close()
}

/// HTTP/1.1 over a pinned mTLS NWConnection. Responses must carry Content-Length, which
/// every gateway JSON reply does; anything else is `malformed`.
nonisolated final class RoomConnection: RoomTransport, @unchecked Sendable {
    static let hostHeader = "room.localhost"
    private static let maxResponseBytes = 1 << 20

    let connection: NWConnection
    private let capture = PeerCapture()
    private let pin: ServerPin
    private let queue = DispatchQueue(label: "benchbar.share.room-connection")
    private var buffer = Data()

    init(endpoint: NWEndpoint, identity: SecIdentity, pin: ServerPin) {
        self.pin = pin
        connection = NWConnection(to: endpoint, using: PinnedTLS.parameters(identity: identity, pin: pin, capture: capture))
    }

    var serverSPKIHash: Data? { capture.spkiHash }
    var exporter: Data? { PinnedTLS.exporter(of: connection) }
    var remoteEndpoint: NWEndpoint? { connection.currentPath?.remoteEndpoint }

    func open(timeout: TimeInterval = 8) async throws(RoomConnectionError) {
        let result: Result<Void, RoomConnectionError> = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            let finish: @Sendable (Result<Void, RoomConnectionError>) -> Void = { result in
                guard once.claim() else { return }
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return finish(.failure(.closed)) }
                switch state {
                case .ready: finish(.success(()))
                case .waiting, .failed: finish(.failure(failureReason()))
                case .cancelled: finish(.failure(.closed))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(.timedOut)) }
        }
        if case .failure(let error) = result {
            connection.cancel()
            throw error
        }
    }

    /// A pinned connection whose server showed another SPKI failed because of the pin, which
    /// Network.framework reports as `.waiting` (a TLS error) before `.failed`.
    private func failureReason() -> RoomConnectionError {
        if case .pinned(let expected) = pin, let seen = capture.spkiHash, seen != expected { return .identityChanged }
        if connection.currentPath?.unsatisfiedReason == .localNetworkDenied { return .localNetworkDenied }
        return .unreachable
    }

    func close() {
        connection.cancel()
    }

    func send(_ method: String, _ path: String, body: Data?) async throws(RoomConnectionError) -> RoomResponse {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(Self.hostHeader)\r\nAccept: application/json\r\n"
        if let body { head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" }
        head += "\r\n"
        try await write(Data(head.utf8) + (body ?? Data()))
        return try await readResponse()
    }

    private func write(_ data: Data) async throws(RoomConnectionError) {
        let error: NWError? = await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { continuation.resume(returning: $0) })
        }
        if error != nil { throw .closed }
    }

    private func readMore() async throws(RoomConnectionError) {
        let chunk: Data? = await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data, !data.isEmpty { return continuation.resume(returning: data) }
                continuation.resume(returning: error == nil && !isComplete ? Data() : nil)
            }
        }
        guard let chunk else { throw .closed }
        buffer.append(chunk)
        if buffer.count > Self.maxResponseBytes { throw .malformed }
    }

    private func readResponse() async throws(RoomConnectionError) -> RoomResponse {
        let separator = Data("\r\n\r\n".utf8)
        var headEnd = buffer.range(of: separator)
        while headEnd == nil {
            try await readMore()
            headEnd = buffer.range(of: separator)
        }
        guard let headRange = headEnd, let parsed = RoomResponseHead.parse(buffer[buffer.startIndex..<headRange.lowerBound]) else { throw .malformed }
        buffer = Data(buffer[headRange.upperBound...])
        guard let length = parsed.headers["content-length"].flatMap(Int.init), length >= 0, length <= Self.maxResponseBytes else { throw .malformed }
        while buffer.count < length { try await readMore() }
        let body = Data(buffer.prefix(length))
        buffer = Data(buffer.dropFirst(length))
        return RoomResponse(status: parsed.status, headers: parsed.headers, body: body)
    }
}

/// A response head: the status line and lower-cased header names.
nonisolated enum RoomResponseHead {
    static func parse(_ data: Data) -> (status: Int, headers: [String: String])? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (status, headers)
    }
}

/// Resumes a continuation at most once across racing callbacks.
nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
