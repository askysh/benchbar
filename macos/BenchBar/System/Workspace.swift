import AppKit

/// Things the popover opens outside the app. None of them touch the bench:
/// a browser, Finder, and Terminal running `benchbar logs`.
enum Workspace {
    static func chooseScanFolder(previous: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = "Scan for Frappe benches"
        panel.message = "Choose a folder to search, including its subfolders."
        panel.prompt = "Scan Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = previous.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser
            : URL(fileURLWithPath: previous, isDirectory: true)
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    static func openSite(_ bench: BenchModel) {
        let text = bench.status?.webURL ?? bench.summary.webURL
        guard let url = URL(string: text) else { return }
        NSWorkspace.shared.open(url)
    }

    static func open(_ text: String) {
        guard let url = URL(string: text) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Finder with these files selected (a backup's parts). Missing ones are skipped.
    static func reveal(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func openFolder(_ bench: BenchModel) {
        NSWorkspace.shared.open(URL(fileURLWithPath: bench.path, isDirectory: true))
    }

    /// Opens Terminal with `benchbar logs` following the bench log. A
    /// `.command` file is a shell script Terminal runs when it opens it, so
    /// this needs no Apple Events permission.
    static func openLogs(_ bench: BenchModel, cli: URL) throws {
        try runInTerminal(name: "logs-\(bench.name)", contents: LogsScript.contents(cli: cli.path, bench: bench.path))
    }

    /// Open Console and Open Database: `benchbar console|db` in Terminal.
    static func openShell(_ kind: TerminalScript.Kind, site: String, bench: BenchModel, cli: URL) throws {
        try runInTerminal(name: "\(kind.rawValue)-\(bench.name)-\(site)",
                          contents: TerminalScript.contents(kind, cli: cli.path, bench: bench.path, site: site))
    }

    /// Open Console / Open Database from a view: the error lands on the bench.
    static func openShell(_ kind: TerminalScript.Kind, site: String, bench: BenchModel, store: BenchStore) {
        guard case .ready(let cli) = store.cli else {
            bench.lastError = "The benchbar command line tool is not available."
            return
        }
        do {
            try openShell(kind, site: site, bench: bench, cli: cli)
        } catch {
            bench.lastError = "Could not open Terminal: \(error.localizedDescription)"
        }
    }

    /// The bench folder in an editor (VS Code, Cursor). False when it is not installed.
    @discardableResult
    static func openInEditor(_ bench: BenchModel, editor: Editor) -> Bool {
        guard let app = Editors.appURL(editor.bundleID) else { return false }
        NSWorkspace.shared.open([URL(fileURLWithPath: bench.path, isDirectory: true)], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// Writes a `.command` script (owner only) and has Terminal run it.
    static func runInTerminal(name: String, contents: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BenchBar", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = name.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "_" }
        let script = folder.appendingPathComponent(String(safe) + ".command")
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Asks for the benchbar file. Returns nil when cancelled.
    static func chooseCLI() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose the benchbar command"
        panel.message = "Pick the benchbar file in your benchbar checkout, or ~/.local/bin/benchbar."
        panel.prompt = "Use This"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
