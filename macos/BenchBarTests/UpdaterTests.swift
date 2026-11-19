import Foundation
import Testing
@testable import BenchBar

/// MAC-6: the same file runs in both builds. The default build has no Sparkle; the Sparkle build
/// (BENCHBAR_SPARKLE=YES, built and tested in pull request CI) has the updater and the two keys
/// Sparkle reads from Info.plist, so a rename of a key or a change in sparkle.yml fails here, not
/// on release day.
@Suite("Updater")
struct UpdaterTests {
    @Test func theBuildSaysWhetherSparkleIsIn() {
        // The test target is not built with the app's SPARKLE flag, so the build is told apart by
        // what the app bundle holds: the Sparkle build has the feed key, the default build has none.
        let info = Bundle.main.infoDictionary ?? [:]
        if info["SUFeedURL"] != nil {
            #expect(Updater.isAvailable, "a feed key means the Sparkle build: the updater must be in")
            #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
            #expect((info["SUFeedURL"] as? String)?.hasPrefix("https://") == true, "the feed is https")
            #expect(!((info["SUPublicEDKey"] as? String) ?? "").isEmpty)
        } else {
            #expect(!Updater.isAvailable, "no feed key means the default build: no updater")
            #expect(info["SUPublicEDKey"] == nil)
        }
    }
}
