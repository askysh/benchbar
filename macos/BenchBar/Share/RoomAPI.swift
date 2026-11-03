import Foundation

/// One seat as `GET /_benchbar/seats` lists it (J17: no emails).
nonisolated struct RoomSeat: Decodable, Sendable, Equatable, Identifiable {
    var seat_id: String
    var full_name: String
    var roles: [String]
    var taken_by: String?

    var id: String { seat_id }
}

/// `GET /_benchbar/room`: the roster every guest sees.
nonisolated struct RoomRoster: Decodable, Sendable, Equatable {
    struct Person: Decodable, Sendable, Equatable {
        var name: String
        var model: String?
        var seat: String?
        var online: Bool
    }

    var room: String
    var host: String
    var site: String
    var deadline_epoch: Int
    var people: [Person]
    var you: String
}

/// `GET /_benchbar/hello`: the health ping of a joined guest.
nonisolated struct GatewayHello: Decodable, Sendable, Equatable {
    var device: String
    var user_label: String?
    var deadline_epoch: Int
    var label: String
    var site_label: String
}

nonisolated enum RoomAPIError: Error, Equatable, Sendable {
    /// 403 not_paired: this Mac is not (or no longer) in the room.
    case removed
    case ended
    case seatTaken
    case rateLimited
    case identityChanged
    case unreachable
    case refused
}

/// The joined-guest calls, over a pinned connection that presents the client identity.
nonisolated struct RoomAPI: Sendable {
    let transport: RoomTransport

    func hello() async throws(RoomAPIError) -> GatewayHello {
        try decode(GatewayHello.self, try await call("GET", "/_benchbar/hello", nil))
    }

    /// Pre-auth `GET /room/hello`: its salt changes with every new room.
    func roomHello() async throws(RoomAPIError) -> RoomHello {
        try decode(RoomHello.self, try await call("GET", "/room/hello", nil))
    }

    func seats() async throws(RoomAPIError) -> [RoomSeat] {
        try decode([RoomSeat].self, try await call("GET", "/_benchbar/seats", nil))
    }

    func roster() async throws(RoomAPIError) -> RoomRoster {
        try decode(RoomRoster.self, try await call("GET", "/_benchbar/room", nil))
    }

    /// J10: the opaque seat id, matched exactly by the host.
    func takeSeat(_ seatId: String) async throws(RoomAPIError) {
        let body = try? JSONEncoder().encode(["seat_id": seatId])
        _ = try await call("POST", "/_benchbar/seat", body)
    }

    func leave() async throws(RoomAPIError) {
        _ = try await call("POST", "/_benchbar/leave", Data("{}".utf8))
    }

    private func call(_ method: String, _ path: String, _ body: Data?) async throws(RoomAPIError) -> RoomResponse {
        let reply: RoomResponse
        do {
            reply = try await transport.send(method, path, body: body)
        } catch {
            throw error == .identityChanged ? .identityChanged : .unreachable
        }
        guard reply.status == 200 else {
            switch (reply.status, reply.reason) {
            case (_, "not_paired"): throw .removed
            case (_, "ended"): throw .ended
            case (_, "seat_taken"): throw .seatTaken
            case (429, _): throw .rateLimited
            default: throw .refused
            }
        }
        return reply
    }

    private func decode<T: Decodable>(_ type: T.Type, _ reply: RoomResponse) throws(RoomAPIError) -> T {
        guard let value = reply.json(type) else { throw .refused }
        return value
    }
}
