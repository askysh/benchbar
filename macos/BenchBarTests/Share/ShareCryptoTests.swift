import CryptoKit
import Foundation
import Security
import Testing
@testable import BenchBar

/// tests/share/vectors.json (copied byte for byte into Fixtures): the draft's Appendix B.1
/// vectors and the project's production-parameter vector, which Node also passes.
@Suite struct ShareCryptoTests {
    private let cpace: [String: Any]

    init() throws {
        cpace = try ShareRepo.vectors()["cpace"] as? [String: Any] ?? [:]
    }

    private func vector(_ name: String) -> [String: Any] {
        cpace[name] as? [String: Any] ?? [:]
    }

    @Test func bundledFilesAreByteIdenticalToTheRepository() throws {
        let bundled = try Data(contentsOf: ShareRepo.mapScript)
        let original = try Data(contentsOf: ShareRepo.repoMapScript)
        #expect(SHA256.hash(data: bundled) == SHA256.hash(data: original))
        #expect(try Data(contentsOf: ShareRepo.vectorsFixture) == Data(contentsOf: ShareRepo.repoVectors))
        // Inside the app (xcodebuild's test host) the resource production loads is checked too.
        if let inApp = Bundle.main.url(forResource: CPaceMap.resourceName, withExtension: "js") {
            #expect(SHA256.hash(data: try Data(contentsOf: inApp)) == SHA256.hash(data: original))
        }
    }

    @Test func stringHelpersMatchDraftA1() {
        let strings = vector("strings")
        #expect(CPace.prependLen(Data()) == hex(strings["prepend_len_empty"]))
        #expect(CPace.prependLen(Data("1234".utf8)) == hex(strings["prepend_len_1234"]))
        let args = (strings["lv_cat_args_ascii"] as? [String] ?? []).map { Data($0.utf8) }
        #expect(CPace.lvCat(args) == hex(strings["lv_cat"]))
        #expect(CPace.prependLen(Data(count: 200)).prefix(2) == Data([0xC8, 0x01]))
    }

    @Test func calculateGeneratorMatchesB11() throws {
        let b = vector("b1_1")
        let prs = Data((b["prs_ascii"] as? String ?? "").utf8)
        let (ci, sid) = (hex(b["ci"]), hex(b["sid"]))
        #expect(CPace.generatorString(prs: prs, ci: ci, sid: sid) == hex(b["generator_string"]))
        #expect(CPace.generatorHashU(prs: prs, ci: ci, sid: sid) == hex(b["decoded"]))
        let map = try ShareRepo.map()
        #expect(try CPace.calculateGenerator(prs: prs, ci: ci, sid: sid, map: map) == hex(b["g"]))
        // The map ignores bit 255, as RFC 7748 decoding does.
        #expect(try map.elligator2(hex(b["hash32"])) == hex(b["g"]))
    }

    @Test func iskMatchesB1() throws {
        let b = vector("b1_isk")
        let g = hex(vector("b1_1")["g"])
        let sid = hex(vector("b1_1")["sid"])
        let Ya = try CPace.scalarMult(hex(b["ya"]), g)
        let Yb = try CPace.scalarMult(hex(b["yb"]), g)
        #expect(Ya == hex(b["Ya"]))
        #expect(Yb == hex(b["Yb"]))
        let K = try CPace.scalarMult(hex(b["ya"]), Yb)
        #expect(K == hex(b["K"]))
        #expect(try CPace.scalarMult(hex(b["yb"]), Ya) == K)
        let ADa = Data((b["ada_ascii"] as? String ?? "").utf8)
        let ADb = Data((b["adb_ascii"] as? String ?? "").utf8)
        #expect(CPace.isk(sid: sid, K: K, Ya: Ya, ADa: ADa, Yb: Yb, ADb: ADb) == hex(b["isk"]))
    }

    /// J7: all 12 B.1.10 inputs through the production import path; the all-zero ones abort.
    @Test func lowOrderAndNonCanonicalPointsFollowB110() throws {
        let b = vector("b1_10")
        let inputs = b["u"] as? [String: String] ?? [:]
        let outputs = b["q"] as? [String: String] ?? [:]
        let aborts = Set(b["abort"] as? [String] ?? [])
        #expect(inputs.count == 12)
        for (key, u) in inputs.sorted(by: { $0.key < $1.key }) {
            let result = Result { () throws(CPace.Failure) in try CPace.scalarMult(hex(b["s"]), hex(u)) }
            if aborts.contains(key) {
                #expect(result == .failure(.abort), "u\(key) must abort")
            } else {
                #expect(result == .success(hex(outputs[key])), "u\(key)")
            }
        }
    }

    @Test func productionParametersMatchNode() throws {
        let p = vector("production")
        let map = try ShareRepo.map()
        let g = try CPace.calculateGenerator(prs: Data((p["prs_ascii"] as? String ?? "").utf8), ci: hex(p["salt"]), sid: Data(), map: map)
        #expect(g == hex(p["g"]))
        let Ya = try CPace.scalarMult(hex(p["ya"]), g)
        let Yb = try CPace.scalarMult(hex(p["yb"]), g)
        #expect(Ya == hex(p["Ya"]))
        #expect(Yb == hex(p["Yb"]))
        let K = try CPace.scalarMult(hex(p["ya"]), Yb)
        #expect(K == hex(p["K"]))
        let ADa = CPace.adGuest(name: p["name"] as? String ?? "", model: p["model"] as? String ?? "")
        let ADb = CPace.adHost(room: p["room"] as? String ?? "", requestId: p["request_id"] as? String ?? "")
        #expect(ADa == hex(p["ada"]))
        #expect(ADb == hex(p["adb"]))
        let isk = CPace.isk(sid: Data(), K: K, Ya: Ya, ADa: ADa, Yb: Yb, ADb: ADb)
        #expect(isk == hex(p["isk"]))
        let key = CPace.macKey(sid: Data(), isk: isk)
        #expect(key == hex(p["mac_key"]))
        let (fh, fg, exporter) = (hex(p["fh"]), hex(p["fg"]), hex(p["exporter"]))
        let ta = try CPace.tag(key: key, role: .guest, Ya: Ya, ADa: ADa, Yb: Yb, ADb: ADb, fh: fh, fg: fg, exporter: exporter)
        let tb = try CPace.tag(key: key, role: .host, Ya: Ya, ADa: ADa, Yb: Yb, ADb: ADb, fh: fh, fg: fg, exporter: exporter)
        #expect(ta == hex(p["ta"]))
        #expect(tb == hex(p["tb"]))
        #expect(CPace.verifyTag(expected: tb, got: hex(p["tb"])))
        var flipped = tb
        flipped[5] ^= 0x01
        #expect(!CPace.verifyTag(expected: tb, got: flipped))
        #expect(!CPace.verifyTag(expected: tb, got: tb.prefix(63)))
        // The exporter is in the tag: a different TLS session gives a different Ta (J16).
        var otherExporter = exporter
        otherExporter[0] ^= 0x01
        #expect(try CPace.tag(key: key, role: .guest, Ya: Ya, ADa: ADa, Yb: Yb, ADb: ADb, fh: fh, fg: fg, exporter: otherExporter) != ta)
    }

    @Test func tagRefusesShortBindingInputs() {
        let result = Result { () throws(CPace.Failure) in
            try CPace.tag(key: Data(count: 64), role: .guest, Ya: Data(), ADa: Data(), Yb: Data(), ADb: Data(), fh: Data(count: 32), fg: Data(count: 32), exporter: Data())
        }
        #expect(result == .failure(.abort))
    }

    @Test func mapRefusesWrongLengthInput() throws {
        let map = try ShareRepo.map()
        #expect(throws: CPace.Failure.abort) { try map.elligator2(Data(count: 31)) }
    }

    @Test(arguments: [
        ("482913", "482913"), ("482 913", "482913"), (" 4 8 2 9 1 3 ", "482913"),
        ("48291", nil), ("4829134", nil), ("48291a", nil), ("٤٨٢٩١٣", nil), ("４８２９１３", nil), ("482\u{00A0}913", nil),
    ] as [(String, String?)])
    func roomCodeAcceptsOnlySixASCIIDigits(typed: String, expected: String?) {
        #expect(RoomCode.normalize(typed) == expected)
    }
}

@Suite struct ShareFingerprintTests {
    @Test func storedSPKIGivesStoredFingerprint() throws {
        let spki = try ShareRepo.vectors()["spki"] as? [String: String] ?? [:]
        let der = hex(spki["der_hex"])
        #expect(Fingerprint.spkiSHA256(spki: der) == spki["fingerprint"])
        #expect(Fingerprint.raw(spki: der) == hex(spki["sha256_hex"]))
        #expect(Fingerprint.raw(fingerprint: spki["fingerprint"] ?? "") == hex(spki["sha256_hex"]))
        #expect(Fingerprint.raw(fingerprint: "sha256:XYZ") == nil)
        #expect(Fingerprint.raw(fingerprint: (spki["sha256_hex"] ?? "")) == nil)
    }

    @Test func serverPinMatchesOnlyItsOwnSPKI() throws {
        let spki = try ShareRepo.vectors()["spki"] as? [String: String] ?? [:]
        let der = hex(spki["der_hex"])
        let pin = ServerPin.pinned(Fingerprint.raw(spki: der))
        #expect(pin.matches(leafSPKI: der))
        var other = der
        other[other.count - 1] ^= 0x01
        #expect(!pin.matches(leafSPKI: other))
        #expect(!pin.matches(leafSPKI: Data()))
        #expect(!ServerPin.pinned(Data()).matches(leafSPKI: der))
        #expect(ServerPin.firstJoin.matches(leafSPKI: der))
        #expect(!ServerPin.firstJoin.matches(leafSPKI: Data()))
    }

    @Test func verifyBlockCapturesOffTheMainQueue() async throws {
        // The capture box is written on the verify queue, never the main actor (spike S2).
        let capture = PeerCapture()
        let der = hex((try ShareRepo.vectors()["spki"] as? [String: String] ?? [:])["der_hex"])
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "verify-test").async {
                capture.record(spki: der)
                continuation.resume()
            }
        }
        #expect(capture.spkiHash == Fingerprint.raw(spki: der))
    }
}

@Suite(.serialized) struct ShareIdentityTests {
    @Test func certificateParsesAndCarriesTheKey() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256]
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let notBefore = Date(timeIntervalSince1970: 1_800_000_000)
        let notAfter = Date(timeIntervalSince1970: 2_600_000_000)    // 2052: GeneralizedTime
        let der = try X509.selfSigned(publicKey: publicKey, commonName: "BenchBar guest", notBefore: notBefore, notAfter: notAfter) { tbs in
            SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, nil)! as Data
        }
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "BenchBar guest")
        let certificateKey = try #require(SecCertificateCopyKey(certificate))
        #expect(SecKeyCopyExternalRepresentation(certificateKey, nil) as Data? == SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let spki = try #require(Fingerprint.spki(of: certificate))
        #expect(spki == Fingerprint.spki(p256PublicKey: publicKey))
        #expect(spki.count == 91)
        let dates = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: [String: Any]]
        let before = (dates?[kSecOIDX509V1ValidityNotBefore as String]?[kSecPropertyKeyValue as String] as? NSNumber)?.doubleValue
        let after = (dates?[kSecOIDX509V1ValidityNotAfter as String]?[kSecPropertyKeyValue as String] as? NSNumber)?.doubleValue
        #expect(before == notBefore.timeIntervalSinceReferenceDate)
        #expect(after == notAfter.timeIntervalSinceReferenceDate)
    }

    @Test func keychainIdentityIsStableNonExtractableAndResettable() throws {
        guard let scratch = ScratchKeychain() else {
            Issue.record("no file keychain on this host; the Keychain identity was not exercised")
            return
        }
        let label = "BenchBar Share Identity test \(UUID().uuidString)"
        let identity = KeychainIdentity(label: label, keychain: scratch.keychain)
        defer { try? identity.reset() }
        let first = try identity.spkiDER()
        #expect(try identity.spkiDER() == first)
        // A second instance finds the same key instead of making one.
        #expect(try KeychainIdentity(label: label, keychain: scratch.keychain).spkiDER() == first)

        let secIdentity = try identity.identity()
        var privateKey: SecKey?
        #expect(SecIdentityCopyPrivateKey(secIdentity, &privateKey) == errSecSuccess)
        let key = try #require(privateKey)
        #expect(SecKeyCopyExternalRepresentation(key, nil) == nil, "the private key must not export")
        let keyAttributes = SecKeyCopyAttributes(key) as? [String: Any]
        #expect((keyAttributes?[kSecAttrIsExtractable as String] as? Bool) == false)
        let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data("probe".utf8) as CFData, nil)
        #expect(signature != nil)

        try identity.reset()
        #expect(try identity.spkiDER() != first)
    }
}
