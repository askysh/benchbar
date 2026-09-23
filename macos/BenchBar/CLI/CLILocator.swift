import Foundation

/// Finds the benchbar CLI. Apps started from Finder do not get your shell's
/// PATH, so we never rely on it: we look in fixed places and always call
/// the CLI by absolute path.
///
/// Order:
///   1. the path saved in Settings
///   2. ~/.local/bin/benchbar       (linked by "benchbar repair")
///   3. /opt/homebrew/bin/benchbar  (a future Homebrew formula)
///   4. /usr/local/bin/benchbar
///   5. ~/.local/bin/frappe-mac     (installs from before the rename)
/// If none exists, the app asks once with a file picker.
nonisolated struct CLILocator: Sendable {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }

    func candidates(userPath: String?) -> [String] {
        var list: [String] = []
        if let userPath, !userPath.isEmpty {
            list.append((userPath as NSString).expandingTildeInPath)
        }
        list.append(home.appendingPathComponent(".local/bin/benchbar").path)
        list.append("/opt/homebrew/bin/benchbar")
        list.append("/usr/local/bin/benchbar")
        list.append(home.appendingPathComponent(".local/bin/frappe-mac").path)
        return list
    }

    /// The first executable candidate. A user setting that is not executable
    /// is an error of its own, so a typo in Settings is not silently ignored.
    func locate(userPath: String?) throws(CLIError) -> URL {
        let list = candidates(userPath: userPath)
        if let userPath, !userPath.isEmpty, let first = list.first, !isExecutable(first) {
            throw .notExecutable(path: first)
        }
        if let found = list.first(where: isExecutable) {
            return URL(fileURLWithPath: found)
        }
        throw .notFound(searched: list)
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
