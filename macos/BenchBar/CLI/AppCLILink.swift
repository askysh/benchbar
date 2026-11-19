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

    /// Whether this app may point the link at `target`. The copy in
    /// /Applications is the one the link follows: a copy in ~/Applications
    /// never takes the link from it, and among copies on the same level the
    /// link never goes to an older one (an old copy that was left behind and
    /// launched again would hand every `benchbar` an older CLI).
    /// `current`: where the link leads now, nil when there is none.
    static func mayReplace(current: String?, with target: String, thisVersion: String,
                           exists: (String) -> Bool, versionOf: (String) -> String?) -> Bool {
        guard let current, current != target, exists(current) else { return true }
        let currentSystem = isInSystemApplications(current)
        let targetSystem = isInSystemApplications(target)
        if currentSystem != targetSystem { return targetSystem }
        guard let held = versionOf(current) else { return true }
        return held.compare(thisVersion, options: .numeric) != .orderedDescending
    }

    private static func isInSystemApplications(_ cliPath: String) -> Bool {
        (cliPath as NSString).standardizingPath.hasPrefix("/Applications/")
    }

    /// The version of the app that holds a CLI inside it:
    /// `/Applications/BenchBar.app/Contents/Resources/cli/benchbar`.
    static func appVersion(ofCLI cliPath: String) -> String? {
        guard let range = cliPath.range(of: ".app/") else { return nil }
        let app = String(cliPath[..<range.upperBound].dropLast())
        return Bundle(path: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Makes the link, or points it here. True when it changed. A temporary
    /// link renamed over the old one, so a benchbar starting meanwhile sees
    /// the old link or the new one, never none.
    @discardableResult
    static func register(appBundlePath: String = Bundle.main.bundlePath,
                         home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                         bundled: String? = CLILocator.bundledCLI(),
                         thisVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                         versionOf: (String) -> String? = AppCLILink.appVersion(ofCLI:)) -> Bool {
        guard let target = target(appBundlePath: appBundlePath, home: home, bundled: bundled) else { return false }
        let fm = FileManager.default
        let link = linkPath(home: home)
        let current = try? fm.destinationOfSymbolicLink(atPath: link)
        if current == target { return false }
        guard mayReplace(current: current, with: target, thisVersion: thisVersion,
                         exists: { fm.fileExists(atPath: $0) }, versionOf: versionOf) else { return false }
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
