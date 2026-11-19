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
        let info = Bundle.main.infoDictionary ?? [:]
        #if SPARKLE
        #expect(Updater.isAvailable)
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect((info["SUFeedURL"] as? String)?.hasPrefix("https://") == true, "the feed is https")
        #expect(info["SUPublicEDKey"] as? String != nil)
        #else
        #expect(!Updater.isAvailable)
        #expect(info["SUFeedURL"] == nil, "no feed without Sparkle")
        #endif
    }
}
