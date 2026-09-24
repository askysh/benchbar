import AppKit

#if SPARKLE
import Sparkle

/// Sparkle 2 automatic updates. Only built with BENCHBAR_SPARKLE=YES
/// (scripts/macos-build.sh --sparkle): the default build has no Sparkle
/// code and makes no update checks. The feed URL and the public EdDSA key
/// come from Info.plist (SUFeedURL, SUPublicEDKey); see docs/releasing.md.
final class Updater {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    static let isAvailable = true

    /// "Check for Updates…", for the menus.
    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        item.target = controller
        return item
    }
}
#else
/// The default build: no updater, no menu item.
final class Updater {
    static let isAvailable = false
    func menuItem() -> NSMenuItem? { nil }
}
#endif
