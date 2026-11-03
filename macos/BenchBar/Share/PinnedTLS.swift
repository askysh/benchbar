import Foundation
import Network
import Security

/// What a TLS connection to a room accepts as the server.
/// - `firstJoin`: any leaf; its SPKI is captured for the CPace tags, and authenticity comes
///   from Tb verifying afterwards. Nothing is pinned until then (pin-after-proof, R3.3).
/// - `pinned`: only a leaf whose SPKI SHA-256 equals the stored 32 bytes.
/// The hostname and the chain are ignored on purpose: the host's certificate is self-signed
/// and the SPKI is the only identity it has.
nonisolated enum ServerPin: Sendable, Equatable {
    case firstJoin
    case pinned(Data)

    func matches(leafSPKI: Data) -> Bool {
        switch self {
        case .firstJoin: return !leafSPKI.isEmpty
        case .pinned(let expected): return expected.count == 32 && !leafSPKI.isEmpty && Fingerprint.raw(spki: leafSPKI) == expected
        }
    }
}

/// The server leaf's SPKI hash as this connection saw it in its own handshake (Fh).
/// Written on the verify queue, read after `.ready`.
nonisolated final class PeerCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _spkiHash: Data?

    var spkiHash: Data? { lock.withLock { _spkiHash } }

    func record(spki: Data) {
        lock.withLock { _spkiHash = Fingerprint.raw(spki: spki) }
    }
}

nonisolated enum PinnedTLS {
    private static let verifyQueue = DispatchQueue(label: "benchbar.share.tls-verify")

    /// TLS 1.3 only, ALPN http/1.1, the guest's client identity, and the pin check.
    static func parameters(identity: SecIdentity, pin: ServerPin, capture: PeerCapture) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
        if let local = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(options, local)
        }
        sec_protocol_options_set_verify_block(options, verifyBlock(pin: pin, capture: capture), verifyQueue)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.preferNoProxies = true
        return parameters
    }

    /// Built in a nonisolated function as a @Sendable closure: a closure formed inside a
    /// MainActor type inherits that isolation and traps on the verify queue (spike S2).
    private static func verifyBlock(pin: ServerPin, capture: PeerCapture) -> sec_protocol_verify_t {
        { @Sendable metadata, _, complete in
            guard let spki = leafSPKI(metadata) else { return complete(false) }
            capture.record(spki: spki)
            complete(pin.matches(leafSPKI: spki))
        }
    }

    private static func leafSPKI(_ metadata: sec_protocol_metadata_t) -> Data? {
        var leaf: SecCertificate?
        sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
            if leaf == nil { leaf = sec_certificate_copy_ref(certificate).takeRetainedValue() }
        }
        return leaf.flatMap(Fingerprint.spki(of:))
    }

    /// The RFC 8446 7.5 exporter of this connection: label EXPORTER-bb-join-v3, 32 bytes,
    /// empty context (equal to no context in TLS 1.3; spike S2 matched Node byte for byte).
    static func exporter(of connection: NWConnection) -> Data? {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let label = CPace.exporterLabel
        let secret = label.withCString { sec_protocol_metadata_create_secret(tls.securityProtocolMetadata, label.utf8.count, $0, 32) }
        guard let secret else { return nil }
        let bytes = Data(secret as DispatchData)
        return bytes.count == 32 ? bytes : nil
    }
}
