import Foundation
import Network

/// `benchbar://share/join?v=1&r=&h=&s=&c=&a=&x=` (invite-spec v1). It carries the room code,
/// so a value lives only in the join sheet's memory: never saved, logged or printed. Its
/// description, debug description and mirror leave the code out.
nonisolated struct ShareInvite: Equatable, Sendable {
    enum Problem: Error, Equatable, Sendable {
        /// Paste invite: the text holds no `benchbar://share/join` link.
        case notFound
        /// `v` is not 1.
        case newerVersion
        case malformed
    }

    /// The room label, cleaned like a TXT record (the host chose it).
    var room: String
    /// The host's SPKI SHA-256 (raw 32 bytes): the hello's TLS must show exactly this key.
    var hostPin: Data
    /// The salt `/room/hello` returned for the code in this invite, 32 lowercase hex.
    var salt: String
    var code: String
    /// `a`: a hint only, used when Bonjour has not seen the host. An IPv4 literal and a port.
    var address: Address?
    /// `x`: the share's deadline when the invite was copied. Advisory: `share extend` keeps the
    /// room open past it, so it only explains a room that no longer answers.
    var expires: Date

    struct Address: Equatable, Sendable {
        var host: String
        var port: UInt16
    }

    static func isInviteLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "benchbar" && url.host(percentEncoded: false)?.lowercased() == "share" && url.path(percentEncoded: true) == "/join"
    }

    static func parse(_ url: URL) -> Result<ShareInvite, Problem> {
        guard isInviteLink(url), url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return .failure(.malformed) }
        let known: Set<String> = ["v", "r", "h", "s", "c", "a", "x"]
        var values: [String: String] = [:]
        for item in items where known.contains(item.name) {
            // A second h or c could be read differently by another parser: refuse it.
            guard values[item.name] == nil else { return .failure(.malformed) }
            values[item.name] = item.value ?? ""
        }
        guard let version = values["v"] else { return .failure(.malformed) }
        guard version == "1" else { return .failure(.newerVersion) }
        let room = TXTSanitizer.clean(values["r"] ?? "")
        guard !room.isEmpty,
              let hostHex = values["h"]?.lowercased(), hostHex.count == 64, isHex(hostHex), let hostPin = Data(hex: hostHex),
              let salt = values["s"]?.lowercased(), salt.count == 32, isHex(salt),
              let code = values["c"].flatMap(RoomCode.normalize), values["c"]?.count == 6,
              let deadline = values["x"].flatMap({ $0.allSatisfy(\.isASCII) ? Int64($0) : nil }), deadline > 0
        else { return .failure(.malformed) }
        return .success(ShareInvite(room: room, hostPin: hostPin, salt: salt, code: code,
                                    address: values["a"].flatMap(address), expires: Date(timeIntervalSince1970: TimeInterval(deadline))))
    }

    /// Paste invite: the first `benchbar://share/join` link in a chat message, which may wrap
    /// it in `<…>`, quotes or `<…|label>`, or end the sentence after it.
    static func first(in text: String) -> Result<ShareInvite, Problem> {
        guard let range = text.range(of: #"benchbar://share/join\?[^\s<>"|`]+"#, options: [.regularExpression, .caseInsensitive]) else {
            return .failure(.notFound)
        }
        var link = String(text[range])
        while let last = link.last, ".,;:!?)'".contains(last) { link.removeLast() }
        guard let url = URL(string: link) else { return .failure(.malformed) }
        return parse(url)
    }

    func isExpired(now: Date) -> Bool {
        now >= expires
    }

    private static func isHex(_ text: String) -> Bool {
        text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private static func address(_ text: String) -> Address? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, IPv4Address(String(parts[0])) != nil,
              parts[0].allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              parts[1].allSatisfy(\.isASCII), let port = UInt16(parts[1]), port != 0 else { return nil }
        return Address(host: String(parts[0]), port: port)
    }

    /// What the join compares before any code material leaves this Mac.
    var check: RoomJoin.InviteCheck {
        RoomJoin.InviteCheck(hostPin: hostPin, salt: salt)
    }
}

extension ShareInvite: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ShareInvite(room: \(room), code: hidden)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["room": room, "expires": expires], displayStyle: .struct) }
}
