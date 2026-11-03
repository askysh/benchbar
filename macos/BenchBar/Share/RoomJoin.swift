import Foundation

/// `GET /room/hello`, pre-auth. Display data plus the salt that goes into CI (J15).
nonisolated struct RoomHello: Decodable, Sendable, Equatable {
    var v: Int
    var room: String
    var host: String
    var site: String
    var salt: String
    var locked: Bool
    var full: Bool
    var people: Int
    var seats: Int
}

/// Why a join did not happen. None of these carries the code or anything derived from it.
nonisolated enum JoinRefusal: Error, Equatable, Sendable {
    case invalidCode
    case wrongCode
    case locked
    case full
    case alreadyJoined
    case blocked
    case expired
    case rateLimited(retryAfter: Int)
    case needsUpdate
    /// Tb did not verify: the room is not who it claims, or the code was wrong on its side.
    case codeDidNotCheckOut
    case identityChanged
    case unreachable
    case localNetworkDenied
    case failed
}

nonisolated struct JoinedRoom: Sendable, Equatable {
    var deviceId: String
    /// Fh, pinned for every later connection; set only after Tb verified.
    var hostPin: Data
    var hello: RoomHello
}

nonisolated enum RoomCode {
    /// Exactly six ASCII digits after removing spaces (J13): not Swift's isNumber, which takes
    /// other scripts' digits.
    static func normalize(_ typed: String) -> String? {
        let digits = typed.unicodeScalars.filter { $0 != " " }
        guard digits.count == 6, digits.allSatisfy({ (0x30...0x39).contains($0.value) }) else { return nil }
        return String(String.UnicodeScalarView(digits))
    }
}

/// The guest side of a protocol v3 join (task-2b-spec R3.3, R3.4, J1-J19), mirroring
/// tests/share/helpers.js GuestSession: hello, start and finish on one connection.
nonisolated struct RoomJoin {
    static let nameMax = 40
    static let modelMax = 32
    /// J8: start goes out no earlier than this after the hello reply.
    static let startDelay: Duration = .milliseconds(250)

    var name: String
    var model: String
    var makeMap: @Sendable () throws(CPace.Failure) -> CPaceMap = { () throws(CPace.Failure) in try CPaceMap.bundled() }
    var randomScalar: @Sendable () -> Data = CPace.randomScalar
    var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// The host checks JavaScript string length (UTF-16 units).
    static func clip(_ text: String, max: Int) -> String {
        var out = ""
        for character in text where out.utf16.count + String(character).utf16.count <= max { out.append(character) }
        return out
    }

    /// `fg` is the raw SPKI hash of this Mac's client certificate. The code is used here and
    /// dropped; it is never stored, logged or put into an error (J12).
    func join(over transport: RoomTransport, code typed: String, fg: Data) async -> Result<JoinedRoom, JoinRefusal> {
        guard let code = RoomCode.normalize(typed) else { return .failure(.invalidCode) }
        guard fg.count == 32 else { return .failure(.failed) }
        do throws(JoinRefusal) {
            return .success(try await run(transport, code: code, fg: fg))
        } catch {
            return .failure(error)
        }
    }

    private func run(_ transport: RoomTransport, code: String, fg: Data) async throws(JoinRefusal) -> JoinedRoom {
        let helloReply = try await exchange(transport, "GET", "/room/hello", nil)
        let helloAnswered = ContinuousClock.now
        if helloReply.status == 429 { throw .rateLimited(retryAfter: retryAfter(helloReply)) }
        guard helloReply.status == 200, let hello = helloReply.json(RoomHello.self) else { throw .failed }
        guard hello.v == CPace.protocolVersion else { throw .needsUpdate }
        if hello.locked { throw .locked }
        if hello.full { throw .full }
        guard let salt = Data(hex: hello.salt), salt.count == 16, let fhAtStart = transport.serverSPKIHash else { throw .failed }

        let session: Session
        do {
            let map = try makeMap()
            let generator = try CPace.calculateGenerator(prs: Data(code.utf8), ci: salt, sid: Data(), map: map)
            let ya = randomScalar()
            session = Session(ya: ya, Ya: try CPace.scalarMult(ya, generator))
        } catch {
            throw .failed
        }

        await sleep(Self.startDelay - helloAnswered.duration(to: .now))
        let name = Self.clip(name, max: Self.nameMax)
        let model = Self.clip(model, max: Self.modelMax)
        let startBody = try encode(["v": .int(CPace.protocolVersion), "name": .string(name), "model": .string(model), "Ya": .string(session.Ya.hex)])
        let startReply = try await exchange(transport, "POST", "/room/join/start", startBody)
        guard startReply.status == 200 else { throw refusal(startReply) }
        struct Started: Decodable { var request_id: String; var Yb: String }
        guard let started = startReply.json(Started.self), let Yb = Data(hex: started.Yb), Yb.count == 32 else { throw .failed }

        let ADa = CPace.adGuest(name: name, model: model)
        let ADb = CPace.adHost(room: hello.room, requestId: started.request_id)
        let macKey: Data
        do {
            let K = try CPace.scalarMult(session.ya, Yb)
            macKey = CPace.macKey(sid: Data(), isk: CPace.isk(sid: Data(), K: K, Ya: session.Ya, ADa: ADa, Yb: Yb, ADb: ADb))
        } catch {
            throw .failed
        }

        // Ta binds the finish connection's own Fh and exporter, so read both now (J11, J16).
        guard let fh = transport.serverSPKIHash, fh == fhAtStart, let exporter = transport.exporter else { throw .failed }
        let ta: Data
        let expectedTb: Data
        do {
            ta = try CPace.tag(key: macKey, role: .guest, Ya: session.Ya, ADa: ADa, Yb: Yb, ADb: ADb, fh: fh, fg: fg, exporter: exporter)
            expectedTb = try CPace.tag(key: macKey, role: .host, Ya: session.Ya, ADa: ADa, Yb: Yb, ADb: ADb, fh: fh, fg: fg, exporter: exporter)
        } catch {
            throw .failed
        }
        let finishBody = try encode(["v": .int(CPace.protocolVersion), "request_id": .string(started.request_id), "Ta": .string(ta.hex)])
        let finishReply = try await exchange(transport, "POST", "/room/join/finish", finishBody)
        guard finishReply.status == 200 else { throw refusal(finishReply) }
        struct Finished: Decodable { var status: String; var device_id: String; var Tb: String }
        guard let finished = finishReply.json(Finished.self), finished.status == "joined" else { throw .failed }
        // Pin only after Tb verifies (pin-after-proof).
        guard let tb = Data(hex: finished.Tb), CPace.verifyTag(expected: expectedTb, got: tb) else { throw .codeDidNotCheckOut }
        return JoinedRoom(deviceId: finished.device_id, hostPin: fh, hello: hello)
    }

    private struct Session {
        var ya: Data
        var Ya: Data
    }

    private enum Value: Encodable {
        case int(Int)
        case string(String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .int(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            }
        }
    }

    private func encode(_ object: [String: Value]) throws(JoinRefusal) -> Data {
        do { return try JSONEncoder().encode(object) } catch { throw .failed }
    }

    private func exchange(_ transport: RoomTransport, _ method: String, _ path: String, _ body: Data?) async throws(JoinRefusal) -> RoomResponse {
        do {
            return try await transport.send(method, path, body: body)
        } catch {
            switch error {
            case .identityChanged: throw .identityChanged
            case .localNetworkDenied: throw .localNetworkDenied
            default: throw .unreachable
            }
        }
    }

    private func retryAfter(_ reply: RoomResponse) -> Int {
        struct Limited: Decodable { var retry_after: Int? }
        return reply.json(Limited.self)?.retry_after ?? Int(reply.headers["retry-after"] ?? "") ?? 60
    }

    /// Mapped on the body's `status`, since the gateway reuses HTTP codes (403, 409).
    private func refusal(_ reply: RoomResponse) -> JoinRefusal {
        switch (reply.status, reply.reason) {
        case (426, _): return .needsUpdate
        case (429, _): return .rateLimited(retryAfter: retryAfter(reply))
        case (423, _): return .locked
        case (_, "wrong_code"): return .wrongCode
        case (_, "blocked"): return .blocked
        case (_, "full"): return .full
        case (_, "already_joined"): return .alreadyJoined
        case (_, "unknown_request"), (_, "expired"): return .expired
        default: return .failed
        }
    }
}
