import AppKit

/// A code editor BenchBar can open a bench folder in.
nonisolated struct Editor: Equatable, Sendable, Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

/// Which editors are installed, and which one to use. Pure apart from the
/// lookup, so the choice is tested without the apps.
nonisolated enum Editors {
    static let known = [
        Editor(bundleID: "com.microsoft.VSCode", name: "VS Code"),
        Editor(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        Editor(bundleID: "com.microsoft.VSCodeInsiders", name: "VS Code Insiders"),
    ]

    static func installed(lookup: (String) -> URL?) -> [Editor] {
        known.filter { lookup($0.bundleID) != nil }
    }

    /// The saved choice while it is installed, else the first installed one.
    static func choice(preferred: String, installed: [Editor]) -> Editor? {
        installed.first { $0.bundleID == preferred } ?? installed.first
    }

    /// Launch Services: the app for a bundle id, wherever it is installed.
    static func appURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func installedNow() -> [Editor] { installed(lookup: appURL) }
}

/// The scripts Terminal runs for Open Console and Open Database: the CLI's
/// own commands, which exec bench. No password is in them: `bench mariadb`
/// reads the site's own credentials.
nonisolated enum TerminalScript {
    enum Kind: String, Sendable { case console, db }

    static func contents(_ kind: Kind, cli: String, bench: String, site: String) -> String {
        let what = kind == .console ? "a Python console with frappe" : "the site's database"
        return """
        #!/bin/zsh
        # Opened by BenchBar: \(what) for \(site). Close the window when done.
        clear
        exec \(Shell.quote(cli)) \(kind.rawValue) --site \(Shell.quote(site)) --bench-dir \(Shell.quote(bench))

        """
    }
}
