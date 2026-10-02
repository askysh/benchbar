import Foundation

/// The link ~/.local/state/benchbar/bin/benchbar to the CLI inside this
/// app. Homebrew's and the installer's benchbar run whatever it leads to
/// (lib/frappe-local/install-kind.sh), so every benchbar on the Mac is the
/// app's version; the app makes or re-points it at launch.
///
/// Only an app installed in /Applications or ~/Applications registers:
/// Sparkle and brew replace it in place, so the link outlives updates. A
/// build in Xcode's folder, an app run from the DMG or from Downloads
/// (translocated) does not, so the link never leads somewhere that goes away.
nonisolated enum AppCLILink {
    static func linkPath(home: String) -> String { home + "/.local/state/benchbar/bin/benchbar" }

    /// The CLI to link, nil when this app should not register.
    static func target(appBundlePath: String, home: String, bundled: String?) -> String? {
        guard let bundled else { return nil }
        let parent = ((appBundlePath as NSString).standardizingPath as NSString).deletingLastPathComponent
        guard parent == "/Applications" || parent == (home as NSString).standardizingPath + "/Applications" else { return nil }
        return bundled
    }

    /// Makes the link, or points it here. True when it changed. A temporary
    /// link renamed over the old one, so a benchbar starting meanwhile sees
    /// the old link or the new one, never none.
    @discardableResult
    static func register(appBundlePath: String = Bundle.main.bundlePath,
                         home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                         bundled: String? = CLILocator.bundledCLI()) -> Bool {
        guard let target = target(appBundlePath: appBundlePath, home: home, bundled: bundled) else { return false }
        let fm = FileManager.default
        let link = linkPath(home: home)
        if (try? fm.destinationOfSymbolicLink(atPath: link)) == target { return false }
        let folder = (link as NSString).deletingLastPathComponent
        let temporary = folder + "/.benchbar-\(ProcessInfo.processInfo.processIdentifier)"
        do {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: temporary)
            try fm.createSymbolicLink(atPath: temporary, withDestinationPath: target)
            guard rename(temporary, link) == 0 else {
                try? fm.removeItem(atPath: temporary)
                return false
            }
            return true
        } catch {
            return false
        }
    }
}
