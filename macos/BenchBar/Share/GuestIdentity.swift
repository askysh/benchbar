import Foundation
import Security

/// The guest's stable TLS client identity. Its SPKI is what every host knows this Mac by.
nonisolated protocol IdentityProviding: Sendable {
    func identity() throws -> SecIdentity
    func spkiDER() throws -> Data
}

/// A P-256 key (permanent, non-extractable) plus a self-signed certificate, both in the
/// file-based login keychain: an ad-hoc-signed app has no keychain access group, so the
/// data-protection keychain is out (spike S3). The identity is built with
/// SecIdentityCreateWithCertificate, never a Keychain identity query.
///
/// The key is looked up before anything is created, and an error while looking (a denied
/// ACL prompt, a locked keychain) is thrown rather than answered with a new key: a new key
/// is a new SPKI, which silently breaks every saved room.
nonisolated final class KeychainIdentity: IdentityProviding, @unchecked Sendable {
    static let defaultLabel = "BenchBar Share Identity"

    enum Failure: Error {
        case keychain(OSStatus)
        case keyCreation
        case certificate
    }

    private let label: String
    private let keychain: SecKeychain?
    private let lock = NSLock()

    /// `keychain` nil is the login keychain; tests pass a temporary file keychain.
    init(label: String = KeychainIdentity.defaultLabel, keychain: SecKeychain? = nil) {
        self.label = label
        self.keychain = keychain
    }

    func identity() throws -> SecIdentity {
        try lock.withLock { try loadOrCreate().identity }
    }

    func spkiDER() throws -> Data {
        try lock.withLock {
            let (_, certificate) = try loadOrCreate()
            guard let spki = Fingerprint.spki(of: certificate) else { throw Failure.certificate }
            return spki
        }
    }

    /// Deletes the key and the certificate. The next identity() makes new ones, which every
    /// host sees as a different Mac.
    func reset() throws {
        try lock.withLock {
            for itemClass in [kSecClassCertificate, kSecClassKey] {
                let status = SecItemDelete(scoped([kSecClass as String: itemClass, kSecAttrLabel as String: label]) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
            }
        }
    }

    private func scoped(_ query: [String: Any]) -> [String: Any] {
        guard let keychain else { return query }
        var scopedQuery = query
        scopedQuery[kSecMatchSearchList as String] = [keychain]
        return scopedQuery
    }

    private func find(_ itemClass: CFString, extra: [String: Any] = [:]) throws -> CFTypeRef? {
        var query: [String: Any] = [kSecClass as String: itemClass, kSecAttrLabel as String: label, kSecReturnRef as String: true]
        query.merge(extra) { $1 }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(scoped(query) as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return result
    }

    private func loadOrCreate() throws -> (identity: SecIdentity, certificate: SecCertificate) {
        let certificate: SecCertificate
        if let found = try find(kSecClassCertificate) {
            certificate = found as! SecCertificate
        } else {
            let privateKey = try find(kSecClassKey, extra: [kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]).map { $0 as! SecKey }
                ?? createKey()
            certificate = try makeCertificate(privateKey: privateKey)
        }
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(keychain, certificate, &identity)
        guard status == errSecSuccess, let identity else { throw Failure.keychain(status) }
        return (identity, certificate)
    }

    private func createKey() throws -> SecKey {
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrIsExtractable as String: false,
            kSecAttrLabel as String: label,
        ]
        if let keychain { privateAttributes[kSecUseKeychain as String] = keychain }
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            // The file keychain reads extractability from the top level, not kSecPrivateKeyAttrs.
            kSecAttrIsExtractable as String: false,
            kSecPrivateKeyAttrs as String: privateAttributes,
        ]
        if let keychain { attributes[kSecUseKeychain as String] = keychain }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            error?.release()
            throw Failure.keyCreation
        }
        return key
    }

    private func makeCertificate(privateKey: SecKey) throws -> SecCertificate {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw Failure.certificate }
        let now = Date()
        let der = try X509.selfSigned(publicKey: publicKey, commonName: "BenchBar guest", notBefore: now.addingTimeInterval(-3600),
                                      notAfter: now.addingTimeInterval(20 * 365 * 86400)) { tbs in
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) else {
                error?.release()
                throw Failure.certificate
            }
            return signature as Data
        }
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw Failure.certificate }
        var add: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate, kSecAttrLabel as String: label]
        if let keychain { add[kSecUseKeychain as String] = keychain }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw Failure.keychain(status) }
        return certificate
    }
}
