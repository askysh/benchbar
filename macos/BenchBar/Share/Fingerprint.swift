import CryptoKit
import Foundation
import Security

/// Fingerprints are SPKI SHA-256 hashes everywhere: "sha256:<hex>" for display and storage,
/// the raw 32 bytes in every MAC input (J11).
nonisolated enum Fingerprint {
    static let prefix = "sha256:"

    /// The fixed DER header of a P-256 SubjectPublicKeyInfo, before the 65-byte X9.63 point.
    static let p256SPKIHeader = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ])

    static func raw(spki: Data) -> Data {
        Data(SHA256.hash(data: spki))
    }

    static func spkiSHA256(spki: Data) -> String {
        prefix + raw(spki: spki).hex
    }

    /// "sha256:<64 hex>" back to its 32 bytes; anything else is nil.
    static func raw(fingerprint: String) -> Data? {
        guard fingerprint.hasPrefix(prefix) else { return nil }
        let hex = String(fingerprint.dropFirst(prefix.count))
        guard hex.count == 64, hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return Data(hex: hex)
    }

    /// The SPKI of a P-256 public key: its X9.63 representation behind the fixed header.
    static func spki(p256PublicKey key: SecKey) -> Data? {
        guard let point = SecKeyCopyExternalRepresentation(key, nil) as Data?, point.count == 65, point.first == 0x04 else { return nil }
        return p256SPKIHeader + point
    }

    /// The SubjectPublicKeyInfo exactly as it sits in the certificate, so any key type works.
    static func spki(of leaf: SecCertificate) -> Data? {
        spki(certificateDER: SecCertificateCopyData(leaf) as Data)
    }

    /// Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version OPTIONAL, serial,
    /// signature, issuer, validity, subject, subjectPublicKeyInfo, ... }, ... } (RFC 5280 4.1).
    static func spki(certificateDER der: Data) -> Data? {
        var outer = DERReader(Data(der))
        guard let certificate = outer.next(), certificate.tag == 0x30 else { return nil }
        var certificateBody = DERReader(certificate.content)
        guard let tbs = certificateBody.next(), tbs.tag == 0x30 else { return nil }
        var fields = DERReader(tbs.content)
        guard var field = fields.next() else { return nil }
        if field.tag == 0xA0 {
            guard let afterVersion = fields.next() else { return nil }
            field = afterVersion
        }
        for _ in 0..<5 {
            guard let next = fields.next() else { return nil }
            field = next
        }
        return field.tag == 0x30 ? field.whole : nil
    }
}

/// Just enough DER to walk a certificate: definite lengths, single-byte tags.
nonisolated struct DERReader {
    struct Element {
        var tag: UInt8
        var content: Data
        var whole: Data
    }

    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    mutating func next() -> Element? {
        let start = offset
        guard offset + 2 <= bytes.count else { return nil }
        let tag = bytes[offset]
        var length = Int(bytes[offset + 1])
        offset += 2
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard (1...3).contains(count), offset + count <= bytes.count else { return nil }
            length = bytes[offset..<offset + count].reduce(0) { $0 << 8 | Int($1) }
            offset += count
        }
        guard offset + length <= bytes.count else { return nil }
        let content = Data(bytes[offset..<offset + length])
        offset += length
        return Element(tag: tag, content: content, whole: Data(bytes[start..<offset]))
    }
}
