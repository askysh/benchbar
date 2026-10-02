import Foundation

/// When the automatic check runs and when the update banner shows. Pure,
/// so the once a day rule is tested without a clock or UserDefaults.
nonisolated enum UpdateSchedule {
    /// At most one automatic check per day.
    static let interval: TimeInterval = 24 * 60 * 60

    /// True when an automatic check is due: the setting is on, Sparkle is
    /// not compiled in (it runs its own checks), and the last check is a
    /// day old, never happened, or is in the future (a clock set back).
    static func isDue(now: Date, lastCheck: Date?, automatic: Bool, sparkle: Bool) -> Bool {
        guard automatic, !sparkle else { return false }
        guard let lastCheck else { return true }
        let age = now.timeIntervalSince(lastCheck)
        return age >= interval || age < 0
    }

    /// The version to offer: the latest one seen when it is newer than the
    /// running app. A running version that does not parse (a local build)
    /// is never offered an update.
    static func offer(current: String, latestSeen: String?) -> String? {
        guard let latestSeen, let latest = AppVersion(latestSeen), let mine = AppVersion(current), mine < latest else { return nil }
        return latest.description
    }

    /// The banner shows until it is dismissed for this version; a newer
    /// version shows it again. The menu item stays either way.
    static func showsBanner(offer: String?, dismissed: String?) -> Bool {
        guard let offer else { return false }
        return offer != dismissed
    }
}

/// What Update Now does. BenchBar.app carries its benchbar CLI
/// (Contents/Resources/cli), and Homebrew's or the installer's CLI hand off
/// to it, so updating the app updates the CLI: nothing runs in Terminal.
///
/// - Sparkle built in (every release): Sparkle replaces the app where it
///   is, the cask's app included. The cask has `auto_updates true`, so a
///   later `brew upgrade` compares the app's own version with the tap's
///   and only replaces an app that is older; both channels work.
/// - no Sparkle (a local build): the release page.
///
/// For the cask's app, Copy Command copies `brew upgrade` of the cask,
/// the same update by the other channel.
nonisolated struct UpdatePlan: Equatable, Sendable {
    enum Channel: Equatable, Sendable {
        case sparkle
        case releasePage
    }

    let channel: Channel
    /// The Homebrew prefix whose cask installed this app, nil otherwise.
    let cask: String?

    /// The command Copy Command copies, nil when there is none to offer.
    var command: String? { cask == nil ? nil : Homebrew.upgradeApp }

    /// One or two sentences on what Update Now does, for the banner and the menu's alert.
    var summary: String {
        switch channel {
        case .sparkle:
            "BenchBar's updater downloads and installs the new version, with its command line tool. Your benches keep running."
        case .releasePage:
            "This build of BenchBar has no updater: Update Now opens the release page."
        }
    }

    /// Things the person should know, one sentence each.
    var notes: [String] {
        guard cask != nil else { return [] }
        return ["Homebrew installed BenchBar, so \(Homebrew.upgradeApp) works too; it skips an app that is already up to date."]
    }

    /// Where the app is, as the plan needs it. `live` reads the disk.
    struct Environment: Sendable {
        var home: String
        var appBundlePath: String
        /// Sparkle is built in. UpdateOffer sets it from its own flag.
        var sparkle: Bool = false
        /// For `<prefix>/Caskroom/benchbar-app`.
        var exists: @Sendable (String) -> Bool = { _ in false }

        static func live() -> Environment {
            Environment(home: FileManager.default.homeDirectoryForCurrentUser.path,
                        appBundlePath: Bundle.main.bundlePath,
                        exists: { FileManager.default.fileExists(atPath: $0) })
        }
    }

    static func make(_ env: Environment) -> UpdatePlan {
        // the cask puts the app in /Applications; one in ~/Applications came from install.sh
        let home = (env.home as NSString).standardizingPath
        let parent = ((env.appBundlePath as NSString).standardizingPath as NSString).deletingLastPathComponent
        let cask = parent == home + "/Applications" ? nil : Homebrew.prefixes.first { env.exists($0 + "/Caskroom/benchbar-app") }
        return UpdatePlan(channel: env.sparkle ? .sparkle : .releasePage, cask: cask)
    }
}

/// When the About pane says the command line tool is behind the app. One
/// minor version behind is normal (Homebrew can get a release after
/// Sparkle has updated the app); two or more, or an older major, is not.
nonisolated enum CLIVersionRule {
    /// The version in `benchbar --version`'s first line ("benchbar 0.6.1").
    static func version(fromLine line: String) -> String? {
        line.split(whereSeparator: \.isWhitespace).last.map(String.init).flatMap { AppVersion($0)?.description }
    }

    static func isBehind(cli: String, app: String) -> Bool {
        guard let cli = AppVersion(cli), let app = AppVersion(app) else { return false }
        let (cliMajor, appMajor) = (cli.numbers[0], app.numbers[0])
        if cliMajor != appMajor { return cliMajor < appMajor }
        let cliMinor = cli.numbers.count > 1 ? cli.numbers[1] : 0
        let appMinor = app.numbers.count > 1 ? app.numbers[1] : 0
        return appMinor - cliMinor >= 2
    }

    /// The command that brings that CLI up to date. A CLI before 0.6.0 has
    /// no self-update, so it gets the one line installer without the app.
    static func updateCommand(cli: String, homebrew: Bool) -> String {
        if homebrew { return Homebrew.upgradeCLI }
        if let version = AppVersion(cli), version < AppVersion("0.6.0")! {
            return "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash -s -- --no-app"
        }
        return "benchbar self-update"
    }

    /// The command About shows, nil when the CLI is close enough (or its
    /// version does not parse).
    static func behind(cliLine: String?, app: String, homebrew: Bool) -> String? {
        guard let cliLine, let cli = version(fromLine: cliLine), isBehind(cli: cli, app: app) else { return nil }
        return updateCommand(cli: cli, homebrew: homebrew)
    }
}
