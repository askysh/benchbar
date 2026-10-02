import Foundation

/// Finds the benchbar CLI. Apps started from Finder do not get your shell's
/// PATH, so we never rely on it: we look in fixed places and always call
/// the CLI by absolute path.
///
/// Order:
///   1. the path saved in Settings (a Cellar path counts as its stable
///      <prefix>/opt/benchbar/bin/benchbar; a path that is gone falls
///      back to the rest of this list)
///   2. the CLI inside this app (Contents/Resources/cli/benchbar), the
///      one Homebrew's and the installer's copy hand off to
///   3. /opt/homebrew/bin/benchbar  (Homebrew's formula)
///   4. /usr/local/bin/benchbar     (Homebrew on Intel, only when it is that formula)
///   5. ~/.local/bin/benchbar       (the one line installer's link)
///   6. /usr/local/bin/benchbar     (anything else there)
///   7. ~/.local/bin/frappe-mac     (installs from before the rename)
/// A build from Xcode carries no CLI and starts at 3.
/// If none exists, the app asks once with a file picker.
nonisolated struct CLILocator: Sendable {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    /// False for a dangling link too: its target is gone.
    var exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    var resolve: @Sendable (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    /// The CLI inside this app, nil when the build carries none.
    var bundled: String? = CLILocator.bundledCLI()

    static func bundledCLI(in bundle: Bundle = .main) -> String? {
        guard let resources = bundle.resourceURL else { return nil }
        let path = resources.appendingPathComponent("cli/benchbar").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The Settings path as the locator uses it: tilde expanded, a Cellar
    /// path moved to its opt link. nil for Automatic.
    func saved(_ userPath: String?) -> String? {
        guard let userPath, !userPath.isEmpty else { return nil }
        return Homebrew.stablePath((userPath as NSString).expandingTildeInPath)
    }

    func candidates(userPath: String?) -> [String] {
        var list: [String] = []
        if let saved = saved(userPath) { list.append(saved) }
        if let bundled { list.append(bundled) }
        let usrLocal = "/usr/local/bin/benchbar"
        // a stale /usr/local/bin/benchbar that is not Homebrew's (an old
        // manual copy) must not win over the one line installer's link
        let usrLocalIsBrew = Homebrew.prefix(ofCLI: resolve(usrLocal)) != nil
        list.append("/opt/homebrew/bin/benchbar")
        if usrLocalIsBrew { list.append(usrLocal) }
        list.append(home.appendingPathComponent(".local/bin/benchbar").path)
        if !usrLocalIsBrew { list.append(usrLocal) }
        list.append(home.appendingPathComponent(".local/bin/frappe-mac").path)
        return list
    }

    /// The first executable candidate. A Settings path that exists but is
    /// not executable is an error of its own, so a wrong choice is not
    /// silently ignored; one that is gone (a Cellar folder after brew
    /// cleanup, a moved checkout) falls back to Automatic.
    func locate(userPath: String?) throws(CLIError) -> URL {
        if let saved = saved(userPath) {
            if isExecutable(saved) { return URL(fileURLWithPath: saved) }
            if exists(saved) { throw .notExecutable(path: saved) }
        }
        if let found = candidates(userPath: nil).first(where: isExecutable) {
            return URL(fileURLWithPath: found)
        }
        throw .notFound(searched: candidates(userPath: userPath))
    }

    /// PATH for every CLI call: the CLI itself runs brew, bench, launchctl
    /// and curl, which live in these folders.
    func searchPath() -> String {
        [
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
    }
}

/// Homebrew's benchbar (formula `benchbar`, cask `benchbar-app` in
/// askysh/tap): the commands the app names and how its paths look.
nonisolated enum Homebrew {
    static let install = "brew install askysh/tap/benchbar askysh/tap/benchbar-app"
    static let installCLI = "brew install askysh/tap/benchbar"
    static let upgradeCLI = "brew upgrade askysh/tap/benchbar"
    /// The cask has auto_updates: brew replaces the app only when the app's
    /// own version is older than the tap's, so Sparkle and brew both work.
    static let upgradeApp = "brew upgrade askysh/tap/benchbar-app"
    /// Apple silicon first, then Intel.
    static let prefixes = ["/opt/homebrew", "/usr/local"]

    /// The Homebrew prefix of a benchbar path inside the formula,
    /// `<prefix>/Cellar/benchbar/<version>/...` or `<prefix>/opt/benchbar/bin/`
    /// or `libexec/`; nil for any other path (a checkout in ~/opt/benchbar).
    static func prefix(ofCLI path: String) -> String? {
        for marker in ["/Cellar/benchbar/", "/opt/benchbar/bin/", "/opt/benchbar/libexec/"] {
            if let range = path.range(of: marker) {
                let prefix = String(path[..<range.lowerBound])
                if !prefix.isEmpty { return prefix }
            }
        }
        return nil
    }

    /// A path inside a Cellar folder as `<prefix>/opt/benchbar/bin/benchbar`,
    /// which brew upgrade keeps (brew cleanup deletes the old Cellar folder).
    /// Any other path is returned as it is.
    static func stablePath(_ path: String) -> String {
        guard let range = path.range(of: "/Cellar/benchbar/"), range.lowerBound != path.startIndex else { return path }
        return String(path[..<range.lowerBound]) + "/opt/benchbar/bin/benchbar"
    }
}
