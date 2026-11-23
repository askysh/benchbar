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
    /// Adopt Existing Bench: the folder of one bench (with apps and sites).
    static func chooseExistingBench(previous: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = "Adopt an existing bench"
        panel.message = "Choose the bench folder, the one with apps and sites in it. BenchBar shows the setup plan before it changes anything."
        panel.prompt = "Choose Bench"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = previous.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser
            : URL(fileURLWithPath: previous, isDirectory: true)
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// The folder for a new bench: an existing one, or one made in the panel.
    static func chooseBenchFolder(previous: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose the bench folder"
        panel.message = "Choose or create the folder for the new bench."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let parent = URL(fileURLWithPath: previous, isDirectory: true).deletingLastPathComponent()
        panel.directoryURL = FileManager.default.fileExists(atPath: parent.path) ? parent : FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// A file (the run log) in the app macOS chooses for it.
    static func openFile(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
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

    /// Watch Assets in Terminal: `benchbar watch` for this bench. The error lands on the bench.
    static func openWatch(bench: BenchModel, store: BenchStore) {
        guard case .ready(let cli) = store.cli else {
            bench.lastError = "The benchbar command line tool is not available."
            return
        }
        do {
            try runInTerminal(name: "watch-\(bench.name)", contents: TerminalScript.watchContents(cli: cli.path, bench: bench.path))
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
        let script = try writeScript(name: name, contents: contents, in: folder)

        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Asks for the benchbar file. Returns nil when cancelled.
    static func chooseCLI() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose the benchbar command"
        panel.message = "Pick Homebrew's /opt/homebrew/bin/benchbar, ~/.local/bin/benchbar or the benchbar file in your checkout. No benchbar yet? Install it with \(Homebrew.installCLI), or the one line installer."
        panel.prompt = "Use This"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        let brewBin = Homebrew.prefixes.map { $0 + "/bin" }.first { FileManager.default.fileExists(atPath: $0 + "/benchbar") }
        panel.directoryURL = brewBin.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension Workspace {
    /// A script of this run only: two benches with the same name, or two runs, never share a
    /// file. It is created owner only (no moment with the default mode), and a script older
    /// than a day is removed when the next one is written.
    @discardableResult
    static func writeScript(name: String, contents: String, in folder: URL, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        for old in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if old.pathExtension == "command", let modified, now.timeIntervalSince(modified) > 86_400 { try? fm.removeItem(at: old) }
        }
        let safe = String(name.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "_" })
        let script = folder.appendingPathComponent("\(safe)-\(UUID().uuidString.prefix(8)).command")
        guard fm.createFile(atPath: script.path, contents: Data(contents.utf8), attributes: [.posixPermissions: 0o700]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return script
    }
}
