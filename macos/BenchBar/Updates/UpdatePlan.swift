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
/// (lib/frappe-local/selfupdate.sh) agree.
///
/// The CLI:
/// - in ~/.local/share/benchbar (install.sh's): the installer updates it,
///   with the app unless Homebrew or Sparkle has the app (`--no-app`)
/// - Homebrew's formula (it resolves under `<prefix>/Cellar/benchbar/` or
///   `<prefix>/opt/benchbar/`): `brew upgrade askysh/tap/benchbar`, never
///   the installer
/// - in a git checkout elsewhere (a developer's): left to `git pull`, and
///   the person is told so
/// - somewhere else, not a checkout: left alone
/// - no CLI: the installer installs it (Homebrew, when the app is the cask's)
///
/// The app:
/// - Homebrew's cask (`<prefix>/Caskroom/benchbar-app`, and this app is not
///   in ~/Applications, where only install.sh puts it): never the
///   installer. Sparkle when it is built in, else
///   `brew upgrade --cask --greedy askysh/tap/benchbar-app`
/// - next to Homebrew's CLI in a Sparkle build: Sparkle
/// - otherwise the installer (`--app-only` when it does not update the
///   CLI), as before 0.7.0, a Sparkle build included
/// - replaced by the installer in a writable folder other than
///   ~/Applications (/Applications): BENCHBAR_APP_DIR, so the copy that
///   runs is the one replaced
nonisolated struct UpdatePlan: Equatable, Sendable {
    static let installerURL = "https://raw.githubusercontent.com/askysh/benchbar/main/install.sh"

    /// A release version as the update check reports it (0.6.0, 0.7.0-beta.1).
    static func isReleaseVersion(_ version: String) -> Bool {
        version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$"#, options: .regularExpression) != nil
    }

    /// The installer of that release's tag, so a release published after
    /// the prompt cannot change what runs; main only for an odd version.
    static func installerURL(for version: String) -> String {
        isReleaseVersion(version) ? "https://raw.githubusercontent.com/askysh/benchbar/v\(version)/install.sh" : installerURL
    }

    enum CLI: Equatable, Sendable {
        case managed
        case missing
        /// A git checkout of the person's own, at this folder.
        case checkout(String)
        /// Neither install.sh's nor a checkout, at this folder.
        case other(String)
        /// Homebrew's formula, under this prefix (/opt/homebrew).
        case homebrew(prefix: String)
    }

    enum App: Equatable, Sendable {
        /// The one line installer replaces it.
        case installer
        /// Homebrew's cask under this prefix; brew replaces it.
        case cask(prefix: String)
        /// Sparkle replaces it in place. `cask` is the cask's prefix when
        /// Homebrew installed it.
        case sparkle(cask: String?)
    }

    /// One command Update Now runs in Terminal.
    enum Step: Equatable, Sendable {
        /// install.sh with `--yes`, these flags and the release pin.
        case installer(flags: [String])
        /// A `brew ...` command; the script runs `<prefix>/bin/brew`, since
        /// a `.command` file does not get the person's shell PATH.
        case brew(prefix: String, command: String)
    }

    let cli: CLI
    let app: App
    /// In order, joined with `&&`. Empty when Sparkle alone has work.
    let steps: [Step]
    /// BENCHBAR_APP_DIR for the installer; nil for its default, ~/Applications.
    let appDirectory: String?
    /// Where the updated app will be, to open it again afterwards.
    let installedApp: String
    /// Things the person should know, one sentence each.
    let notes: [String]

    /// The installer updates the app and not the CLI.
    var appOnly: Bool { steps.contains(.installer(flags: ["--app-only"])) }

    /// The app is replaced from Terminal, so BenchBar quits for it and the
    /// script opens it again. False when Sparkle replaces it.
    var replacesApp: Bool {
        switch app {
        case .installer, .cask: true
        case .sparkle: false
        }
    }

    /// Something runs in Terminal; false when Sparkle alone has work.
    var runsInTerminal: Bool { !steps.isEmpty }

    /// `--version` installs the app release the prompt offered, not whatever is latest by then.
    func installerArguments(for version: String) -> [String] {
        let flags = steps.lazy.compactMap { step -> [String]? in
            if case .installer(let flags) = step { return flags }
            return nil
        }.first ?? []
        return ["--yes"] + flags + (Self.isReleaseVersion(version) ? ["--version", "v\(version)"] : [])
    }

    /// The one line to paste in Terminal, pinned to `version`. With nothing
    /// to run (Sparkle has the cask's app), the brew command that forces it.
    func command(to version: String) -> String {
        steps.isEmpty ? Homebrew.upgradeApp : steps.map { line($0, to: version, absoluteBrew: false) }.joined(separator: " && ")
    }

    /// What the `.command` file runs: the same, with brew by its full path.
    func scriptCommand(to version: String) -> String {
        steps.map { line($0, to: version, absoluteBrew: true) }.joined(separator: " && ")
    }

    private func line(_ step: Step, to version: String, absoluteBrew: Bool) -> String {
        switch step {
        case .installer:
            let env = appDirectory.map { "BENCHBAR_APP_DIR=\(Shell.quote($0)) " } ?? ""
            return "curl -fsSL \(Self.installerURL(for: version)) | \(env)bash -s -- \(installerArguments(for: version).joined(separator: " "))"
        case .brew(let prefix, let command):
            guard absoluteBrew, command.hasPrefix("brew ") else { return command }
            return Shell.quote(prefix + "/bin/brew") + command.dropFirst("brew".count)
        }
    }

    /// "the installer", "Homebrew" or both, in the order they run.
    private var tools: String {
        var names: [String] = []
        for step in steps {
            let name: String
            switch step {
            case .installer: name = "the installer"
            case .brew: name = "Homebrew"
            }
            if !names.contains(name) { names.append(name) }
        }
        return names.joined(separator: " and ")
    }

    /// One or two sentences on what Update Now does, for the banner and the menu's alert.
    var summary: String {
        if replacesApp {
            return "Terminal opens and runs \(tools). BenchBar quits while it is replaced and opens again at the end; your benches keep running."
        }
        if steps.isEmpty {
            return "BenchBar's updater downloads and installs the new version; your benches keep running."
        }
        return "Terminal opens and runs \(tools) for the command line tool, and BenchBar's updater offers the new app. Your benches keep running."
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
        /// Sparkle is built in. UpdateOffer sets it from its own flag.
        var sparkle: Bool = false
        /// For `<prefix>/Caskroom/benchbar-app`.
        var exists: @Sendable (String) -> Bool = { _ in false }

        static func live(cliPath: String?) -> Environment {
            Environment(
                home: FileManager.default.homeDirectoryForCurrentUser.path,
                cliPath: cliPath,
                appBundlePath: Bundle.main.bundlePath,
                resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                isGitCheckout: { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git")) },
                isWritable: { FileManager.default.isWritableFile(atPath: $0) },
                exists: { FileManager.default.fileExists(atPath: $0) })
        }
    }

    static func make(_ env: Environment) -> UpdatePlan {
        let home = (env.home as NSString).standardizingPath
        var notes: [String] = []

        let cli: CLI
        if let path = env.cliPath {
            let resolved = env.resolve(path)
            let folder = ((resolved as NSString).deletingLastPathComponent as NSString).standardizingPath
            let managed = (env.resolve(home + "/.local/share/benchbar") as NSString).standardizingPath
            if let prefix = Homebrew.prefix(ofCLI: resolved) ?? Homebrew.prefix(ofCLI: path) {
                cli = .homebrew(prefix: prefix)
                notes.append("Your benchbar comes from Homebrew, so Homebrew updates it: \(Homebrew.upgradeCLI). A release can reach Homebrew a little after GitHub.")
            } else if folder == managed {
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

        // Homebrew's cask puts the app in /Applications; one in
        // ~/Applications came from install.sh even when a cask is there too
        let userApps = home + "/Applications"
        let bundle = (env.appBundlePath as NSString).standardizingPath
        let parent = (bundle as NSString).deletingLastPathComponent
        var prefixes = Homebrew.prefixes
        if case .homebrew(let prefix) = cli, !prefixes.contains(prefix) { prefixes.insert(prefix, at: 0) }
        let cask = parent == userApps ? nil : prefixes.first { env.exists($0 + "/Caskroom/benchbar-app") }

        let app: App
        if let cask {
            app = env.sparkle ? .sparkle(cask: cask) : .cask(prefix: cask)
        } else if case .homebrew = cli, env.sparkle {
            app = .sparkle(cask: nil)
        } else {
            app = .installer
        }

        var steps: [Step] = []
        switch cli {
        case .managed:
            steps.append(.installer(flags: app == .installer ? [] : ["--no-app"]))
        case .missing:
            if let cask {
                steps.append(.brew(prefix: cask, command: Homebrew.installCLI))
                notes.append("No benchbar was found, so Homebrew installs it: \(Homebrew.installCLI)")
            } else {
                steps.append(.installer(flags: []))
            }
        case .homebrew(let prefix):
            steps.append(.brew(prefix: prefix, command: Homebrew.upgradeCLI))
            if app == .installer { steps.append(.installer(flags: ["--app-only"])) }
        case .checkout, .other:
            if app == .installer { steps.append(.installer(flags: ["--app-only"])) }
        }
        switch app {
        case .cask(let prefix):
            steps.append(.brew(prefix: prefix, command: Homebrew.upgradeApp))
            notes.append("BenchBar came from Homebrew's cask benchbar-app, so Homebrew replaces it: \(Homebrew.upgradeApp)")
        case .sparkle:
            notes.append(steps.isEmpty
                ? "BenchBar updates itself with its own updater; nothing runs in Terminal."
                : "BenchBar updates itself: its own updater offers the new version once Terminal has started.")
        case .installer:
            break
        }

        var appDirectory: String?
        if app == .installer && parent != userApps {
            if parent == "/Applications" && env.isWritable(parent) {
                appDirectory = parent
            } else {
                notes.append("This copy of BenchBar runs from \(parent); the update installs into ~/Applications. Move the old copy to the Trash afterwards.")
            }
        }
        let installedApp = app == .installer ? (appDirectory ?? userApps) + "/BenchBar.app" : bundle
        return UpdatePlan(cli: cli, app: app, steps: steps, appDirectory: appDirectory, installedApp: installedApp, notes: notes)
    }

    /// The `.command` file Terminal runs for Update Now: the commands, the
    /// notes, then the app opened again when it was replaced (the new one,
    /// or the old one when the update failed). It deletes itself at the end.
    func script(from current: String, to version: String) -> String {
        let noteLines = notes.map { "echo \(Shell.quote($0))" }.joined(separator: "\n")
        let run = scriptCommand(to: version)
        let done = replacesApp ? "BenchBar is updated. Opening it again." : "The command line tool is updated. BenchBar's updater takes care of the app."
        let reopen = replacesApp ? "[ -d \(Shell.quote(installedApp)) ] && open \(Shell.quote(installedApp))" : ":"
        return """
        #!/bin/bash
        # Opened by BenchBar \(current): updates BenchBar to \(version) with \(tools).
        # Your benches keep running.\(replacesApp ? " BenchBar quits while it is replaced and opens again at the end." : "")
        set -o pipefail
        clear
        echo \(Shell.quote("Updating BenchBar \(current) to \(version)"))
        echo \(Shell.quote("$ \(run)"))
        echo
        \(run)
        code=$?
        echo
        \(noteLines.isEmpty ? ":" : noteLines)
        if [ "$code" -eq 0 ]; then
          echo \(Shell.quote(done))
        else
          echo "The update did not finish (exit $code). Run it again with the command above, or see https://benchbar.akashmishra.com/install/"
        fi
        \(reopen)
        rm -f "$0"

        """
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
            return "curl -fsSL \(UpdatePlan.installerURL) | bash -s -- --no-app"
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
