import Foundation
import Testing
@testable import BenchBar

@Suite("Share center", .serialized)
struct ShareCenterTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "benchbar-tests-\(UUID().uuidString)"))
    }

    @Test func nothingRunsUntilASharingViewAsksForAStore() throws {
        let center = ShareCenter(defaults: try defaults())
        center.attach(BenchStore(settings: AppSettings(defaults: try defaults())))
        #expect(!center.isWatching, "no network monitor or wake observer at launch")
        #expect(center.stores.isEmpty, "no store, so no share status call")
        center.restoreActive(among: ["/a", "/b"])
        #expect(center.stores.isEmpty && !center.isWatching, "nothing was sharing at the last quit")
        #expect(center.showsTab(for: "/a"))
    }

    @Test func onlyABenchThatWasSharingIsRestored() throws {
        let defaults = try defaults()
        defaults.set(["/b"], forKey: ShareCenter.activeKey)
        let center = ShareCenter(defaults: defaults)
        #expect(center.savedActive == ["/b"])
        // without a CLI there is no store to make, and still no monitor
        center.restoreActive(among: ["/a", "/b"])
        #expect(center.stores.isEmpty && !center.isWatching)
    }
}
