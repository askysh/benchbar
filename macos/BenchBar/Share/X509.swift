import Foundation
import Security

/// A minimal DER encoder for one self-signed X.509 v3 certificate (ecdsa-with-SHA256,
/// P-256), proven in spike S3: OpenSSL and SecCertificateCreateWithData both accept it.
/// No extensions: the host pins the SPKI and ignores everything else.
nonisolated enum X509 {
    enum Failure: Error {
        case notP256
        case signing
    }

    private static let ecdsaWithSHA256 = tlv(0x30, [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])

    /// `sign` gets the TBS bytes and returns a DER ECDSA signature (what
    /// SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256) produces, and what X.509 wants).
    static func selfSigned(publicKey: SecKey, commonName: String, notBefore: Date, notAfter: Date,
                           serial: [UInt8] = randomSerial(), sign: (Data) throws -> Data) throws -> Data {
        guard let spki = Fingerprint.spki(p256PublicKey: publicKey) else { throw Failure.notP256 }
        let version: [UInt8] = [0xA0, 0x03, 0x02, 0x01, 0x02]
        let validity = tlv(0x30, time(notBefore) + time(notAfter))
        let tbs = tlv(0x30, version + tlv(0x02, serial) + ecdsaWithSHA256 + name(commonName) + validity + name(commonName) + [UInt8](spki))
        let signature: Data
        do {
            signature = try sign(Data(tbs))
        } catch {
            throw Failure.signing
        }
        return Data(tlv(0x30, tbs + ecdsaWithSHA256 + tlv(0x03, [0x00] + [UInt8](signature))))
    }

    /// Positive, nonzero leading byte (RFC 5280 4.1.2.2).
    static func randomSerial() -> [UInt8] {
        var serial = (0..<8).map { _ in UInt8.random(in: 0...255) }
        serial[0] = serial[0] & 0x7f | 0x01
        return serial
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let count = content.count
        let length: [UInt8] = count < 0x80 ? [UInt8(count)]
            : count < 0x100 ? [0x81, UInt8(count)]
            : [0x82, UInt8(count >> 8), UInt8(count & 0xff)]
        return [tag] + length + content
    }

    private static func name(_ commonName: String) -> [UInt8] {
        tlv(0x30, tlv(0x31, tlv(0x30, [0x06, 0x03, 0x55, 0x04, 0x03] + tlv(0x0C, Array(commonName.utf8)))))
    }

    /// UTCTime through 2049, GeneralizedTime after (RFC 5280 4.1.2.5).
    private static func time(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2000
        if year < 2050 {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(0x17, Array(formatter.string(from: date).utf8))
        }
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return tlv(0x18, Array(formatter.string(from: date).utf8))
    }
}
