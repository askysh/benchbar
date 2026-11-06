import CryptoKit
import Foundation

/// CPace-X25519-SHA512 pinned to draft-irtf-cfrg-cpace-21, initiator-responder (guest = A,
/// host = B), plus the channel-binding tags of protocol v3. A byte-for-byte port of
/// lib/frappe-local/share/cpace.js; the Elligator2 map itself runs that repo's
/// cpace-map.js in JavaScriptCore (CPaceMap), so there is one implementation of it.
nonisolated enum CPace {
    /// Errors carry no inputs: nothing derived from the room code may reach a log (J9).
    enum Failure: Error, Equatable {
        case abort
        case mapUnavailable
    }

    enum Role: String {
        case guest, host
    }

    static let exporterLabel = "EXPORTER-bb-join-v3"
    static let versionLabel = "bb-join-v3"
    static let protocolVersion = 3
    private static let dsi = Data("CPace255".utf8)
    private static let dsiISK = Data("CPace255_ISK".utf8)
    private static let hashBlockBytes = 128

    static func sha512(_ parts: Data...) -> Data {
        var hasher = SHA512()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    /// Draft A.1.1: LEB128 length prefix.
    static func prependLen(_ data: Data) -> Data {
        var out = Data()
        var length = data.count
        repeat {
            out.append(length < 128 ? UInt8(length) : UInt8(length & 0x7f) | 0x80)
            length >>= 7
        } while length != 0
        return out + data
    }

    static func lvCat(_ parts: Data...) -> Data {
        lvCat(parts)
    }

    static func lvCat(_ parts: [Data]) -> Data {
        parts.reduce(into: Data()) { $0.append(prependLen($1)) }
    }

    /// Draft A.2: zero padding fills the first hash block after DSI and PRS.
    static func generatorString(prs: Data, ci: Data, sid: Data, dsi: Data = CPace.dsi) -> Data {
        let zeros = max(0, hashBlockBytes - 1 - prependLen(prs).count - prependLen(dsi).count)
        return lvCat(dsi, prs, Data(count: zeros), ci, sid)
    }

    /// SHA-512 truncated to 32 bytes with bit 255 cleared (B.1.1 "decoded field element");
    /// the reduction mod p happens in the map. Runs natively (J8): only these 32 bytes reach JavaScript.
    static func generatorHashU(prs: Data, ci: Data, sid: Data) -> Data {
        var u = Data(sha512(generatorString(prs: prs, ci: ci, sid: sid)).prefix(32))
        u[u.startIndex + 31] &= 0x7f
        return u
    }

    static func calculateGenerator(prs: Data, ci: Data, sid: Data, map: CPaceMap) throws(Failure) -> Data {
        try map.elligator2(generatorHashU(prs: prs, ci: ci, sid: sid))
    }

    /// Constant time: the OR never short-circuits.
    static func isAllZero(_ bytes: Data) -> Bool {
        bytes.reduce(UInt8(0)) { $0 | $1 } == 0
    }

    /// X25519 from raw bytes. CryptoKit clamps the scalar. Bit 255 of u is masked here
    /// (RFC 7748) rather than left to the library. Any CryptoKit refusal and an all-zero
    /// result are the same abort, and the explicit zero check runs after every call (J7).
    static func scalarMult(_ scalar: Data, _ u: Data) throws(Failure) -> Data {
        guard scalar.count == 32, u.count == 32 else { throw .abort }
        var point = Data(u)
        point[point.startIndex + 31] &= 0x7f
        let shared: Data
        do {
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar)
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: point)
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            shared = secret.withUnsafeBytes { Data($0) }
        } catch {
            throw .abort
        }
        if isAllZero(shared) { throw .abort }
        return shared
    }

    /// Draft 9.4 with transcript_ir (A.3.4).
    static func isk(sid: Data, K: Data, Ya: Data, ADa: Data, Yb: Data, ADb: Data) -> Data {
        sha512(lvCat(dsiISK, sid, K), lvCat(Ya, ADa), lvCat(Yb, ADb))
    }

    /// A plain concatenation, not an lv_cat (draft 10.4).
    static func macKey(sid: Data, isk: Data) -> Data {
        sha512(Data("CPaceMac".utf8), sid, isk)
    }

    /// lv_cat(role, Ya, ADa, Yb, ADb, Fh, Fg, exporter). Fh and Fg are the raw 32-byte SPKI
    /// hashes each side saw in its own handshake (J11); exporter is that connection's 32-byte
    /// TLS exporter (J16).
    static func tag(key: Data, role: Role, Ya: Data, ADa: Data, Yb: Data, ADb: Data, fh: Data, fg: Data, exporter: Data) throws(Failure) -> Data {
        guard fh.count == 32, fg.count == 32, exporter.count == 32 else { throw .abort }
        let message = lvCat(Data(role.rawValue.utf8), Ya, ADa, Yb, ADb, fh, fg, exporter)
        return Data(HMAC<SHA512>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// Constant time over equal lengths; a length mismatch is public.
    static func verifyTag(expected: Data, got: Data) -> Bool {
        guard expected.count == got.count else { return false }
        return zip(expected, got).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// ADa is the exact UTF-8 bytes sent (J11): no normalisation.
    static func adGuest(name: String, model: String) -> Data {
        lvCat(Data(versionLabel.utf8), Data(name.utf8), Data(model.utf8))
    }

    static func adHost(room: String, requestId: String) -> Data {
        lvCat(Data(versionLabel.utf8), Data(room.utf8), Data(requestId.utf8))
    }

    static func randomScalar() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

nonisolated extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
