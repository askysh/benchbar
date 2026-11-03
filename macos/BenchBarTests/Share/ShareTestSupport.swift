import Foundation
import Security
@testable import BenchBar

/// Files in the repository, found from this source file, so the bundled copies can be
/// compared with the originals they must not drift from.
nonisolated enum ShareRepo {
    static let macos = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let root = macos.deletingLastPathComponent()

    static var mapScript: URL { macos.appendingPathComponent("BenchBar/Resources/cpace-map.js") }
    static var repoMapScript: URL { root.appendingPathComponent("lib/frappe-local/share/cpace-map.js") }
    static var vectorsFixture: URL { macos.appendingPathComponent("BenchBarTests/Fixtures/share-vectors.json") }
    static var repoVectors: URL { root.appendingPathComponent("tests/share/vectors.json") }

    static func vectors() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: vectorsFixture)) as? [String: Any] ?? [:]
    }

    static func map() throws -> CPaceMap {
        try CPaceMap(scriptURL: mapScript)
    }
}

nonisolated func hex(_ value: Any?) -> Data {
    Data(hex: value as? String ?? "") ?? Data()
}

/// A throwaway file keychain, deleted when the value goes away, so tests never touch the
/// login keychain.
nonisolated final class ScratchKeychain {
    let keychain: SecKeychain
    let path: String

    init?() {
        path = NSTemporaryDirectory() + "bb-share-\(UUID().uuidString).keychain"
        let password = "scratch"
        var created: SecKeychain?
        guard SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &created) == errSecSuccess, let created else { return nil }
        keychain = created
    }

    deinit {
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(atPath: path)
    }
}
