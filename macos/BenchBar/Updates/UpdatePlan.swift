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

/// What Update Now runs, decided from where the benchbar CLI and this app
/// are. One place for the rule, so the app and `benchbar self-update`
/// (lib/frappe-local/selfupdate.sh) agree:
///
/// - the CLI in ~/.local/share/benchbar (install.sh's): CLI and app
/// - the CLI in a git checkout elsewhere (a developer's): `--app-only`, and
///   the person is told to `git pull` their checkout
/// - the CLI somewhere else, not a checkout: `--app-only`
/// - no CLI: the installer installs it
/// - the app in a writable folder other than ~/Applications (/Applications):
///   BENCHBAR_APP_DIR, so the copy that runs is the one replaced
nonisolated struct UpdatePlan: Equatable, Sendable {
    static let installerURL = "https://raw.githubusercontent.com/askysh/benchbar/main/install.sh"

    enum CLI: Equatable, Sendable {
        case managed
        case missing
        /// A git checkout of the person's own, at this folder.
        case checkout(String)
        /// Neither install.sh's nor a checkout, at this folder.
        case other(String)
    }

    let cli: CLI
    /// BENCHBAR_APP_DIR for the installer; nil for its default, ~/Applications.
    let appDirectory: String?
    /// Where the updated app will be, to open it again afterwards.
    let installedApp: String
    /// Things the person should know, one sentence each.
    let notes: [String]

    var appOnly: Bool {
        switch cli {
        case .managed, .missing: false
        case .checkout, .other: true
        }
    }

    var installerArguments: [String] { appOnly ? ["--yes", "--app-only"] : ["--yes"] }

    /// The one line to paste in Terminal.
    var command: String {
        let env = appDirectory.map { "BENCHBAR_APP_DIR=\(Shell.quote($0)) " } ?? ""
        return "curl -fsSL \(Self.installerURL) | \(env)bash -s -- \(installerArguments.joined(separator: " "))"
    }

    /// Where things are, as the app sees them. `live` reads the disk.
    struct Environment: Sendable {
        var home: String
        /// The benchbar the app runs (often ~/.local/bin/benchbar, a link), nil when not found.
        var cliPath: String?
        var appBundlePath: String
        var resolve: @Sendable (String) -> String
        var isGitCheckout: @Sendable (String) -> Bool
        var isWritable: @Sendable (String) -> Bool

        static func live(cliPath: String?) -> Environment {
            Environment(
                home: FileManager.default.homeDirectoryForCurrentUser.path,
                cliPath: cliPath,
                appBundlePath: Bundle.main.bundlePath,
                resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                isGitCheckout: { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git")) },
                isWritable: { FileManager.default.isWritableFile(atPath: $0) })
        }
    }

    static func make(_ env: Environment) -> UpdatePlan {
        let home = (env.home as NSString).standardizingPath
        var notes: [String] = []

        let cli: CLI
        if let path = env.cliPath {
            let folder = ((env.resolve(path) as NSString).deletingLastPathComponent as NSString).standardizingPath
            let managed = (env.resolve(home + "/.local/share/benchbar") as NSString).standardizingPath
            if folder == managed {
                cli = .managed
            } else if env.isGitCheckout(folder) {
                cli = .checkout(folder)
                notes.append("Your benchbar is a git checkout at \(folder): only the app is updated. Update the CLI with: git -C \(Shell.quote(folder)) pull")
            } else {
                cli = .other(folder)
                notes.append("Your benchbar at \(folder) was not installed by install.sh: only the app is updated. Update the CLI the way you installed it.")
            }
        } else {
            cli = .missing
        }

        let userApps = home + "/Applications"
        let parent = ((env.appBundlePath as NSString).deletingLastPathComponent as NSString).standardizingPath
        var appDirectory: String?
        if parent != userApps {
            if parent == "/Applications" && env.isWritable(parent) {
                appDirectory = parent
            } else {
                notes.append("This copy of BenchBar runs from \(parent); the update installs into ~/Applications. Move the old copy to the Trash afterwards.")
            }
        }
        let installedApp = (appDirectory ?? userApps) + "/BenchBar.app"
        return UpdatePlan(cli: cli, appDirectory: appDirectory, installedApp: installedApp, notes: notes)
    }

    /// The `.command` file Terminal runs for Update Now: the installer, the
    /// notes, then the app opened again (the new one, or the old one when
    /// the update failed). It deletes itself at the end.
    func script(from current: String, to version: String) -> String {
        let env = appDirectory.map { "BENCHBAR_APP_DIR=\(Shell.quote($0)) " } ?? ""
        let noteLines = notes.map { "echo \(Shell.quote($0))" }.joined(separator: "\n")
        return """
        #!/bin/bash
        # Opened by BenchBar \(current): updates BenchBar to \(version) with the one line installer.
        # Your benches keep running. BenchBar quits while it is replaced and opens again at the end.
        set -o pipefail
        clear
        echo \(Shell.quote("Updating BenchBar \(current) to \(version)"))
        echo \(Shell.quote("$ \(command)"))
        echo
        curl -fsSL \(Self.installerURL) | \(env)bash -s -- \(installerArguments.joined(separator: " "))
        code=$?
        echo
        \(noteLines.isEmpty ? ":" : noteLines)
        if [ "$code" -eq 0 ]; then
          echo "BenchBar is updated. Opening it again."
        else
          echo "The update did not finish (exit $code). Run it again with the command above, or see https://benchbar.akashmishra.com/install/"
        fi
        [ -d \(Shell.quote(installedApp)) ] && open \(Shell.quote(installedApp))
        rm -f "$0"

        """
    }
}
