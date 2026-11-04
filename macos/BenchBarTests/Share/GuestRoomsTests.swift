import Foundation
import Testing
@testable import BenchBar

@Suite struct TXTSanitizerTests {
    @Test func onlyKnownKeysCleanedAndCapped() {
        let display = TXTSanitizer.display(txt: [
            "v": "3", "label": "Priya\u{202E}s  room\nnext" + String(repeating: "x", count: 60), "site": "macdev", "fp8": "deadbeef", "evil": "<script>",
        ])
        #expect(display.label.count == 40)
        #expect(!display.label.contains("\u{202E}") && !display.label.contains("\n") && !display.label.contains("  "))
        #expect(display.label.hasPrefix("Priya s room next"))
        #expect(display.site == "macdev")
        #expect(!display.needsUpdate)
        let rendered = "\(display.label)\(display.site)"
        #expect(!rendered.contains("deadbeef") && !rendered.contains("<script>"))
    }

    @Test func aMissingOrOtherVersionNeedsAnUpdate() {
        #expect(TXTSanitizer.display(txt: ["label": "Room"]).needsUpdate)
        #expect(TXTSanitizer.display(txt: ["label": "Room"]).label == "Room")
        #expect(TXTSanitizer.display(txt: ["v": "2", "label": "Room"]).needsUpdate)
    }
}

@Suite struct SavedRoomsTests {
    private func room(_ fp: String = "sha256:" + String(repeating: "ab", count: 32), device: String = "d_1") -> SavedRoom {
        SavedRoom(hostFingerprint: fp, deviceId: device, room: "Standup", host: "Priya", site: "macdev", serviceName: "Priya's room",
                  lastHost: "192.168.1.9", port: 8443, localPort: 41234, joinedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func roundTripsAndReplacesTheSameHost() throws {
        let defaults = try #require(UserDefaults(suiteName: "share-rooms-\(UUID().uuidString)"))
        let store = SavedRoomsStore(defaults: defaults)
        store.save(room())
        store.save(room(device: "d_2"))
        #expect(store.load() == [room(device: "d_2")])
        #expect(store.load().first?.hostPin?.count == 32)
        store.forget(room())
        #expect(store.load().isEmpty)
    }

    @Test func nothingSecretIsWritten() throws {
        let defaults = try #require(UserDefaults(suiteName: "share-rooms-\(UUID().uuidString)"))
        SavedRoomsStore(defaults: defaults).save(room())
        let stored = String(decoding: try #require(defaults.data(forKey: SavedRoomsStore.key)), as: UTF8.self)
        for word in ["code", "isk", "mac_key", "ya", "Ya", "secret", "password", "Ta", "Tb"] {
            #expect(!stored.contains("\"\(word)\""), "\(word)")
        }
    }
}
