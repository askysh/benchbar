import AppKit

/// Things the popover opens outside the app. None of them touch the bench:
/// a browser, Finder, and Terminal running `benchbar logs`.
enum Workspace {
    static func openSite(_ bench: BenchModel) {
        let text = bench.status?.webURL ?? bench.summary.webURL
        guard let url = URL(string: text) else { return }
        NSWorkspace.shared.open(url)
    }

    static func openFolder(_ bench: BenchModel) {
        NSWorkspace.shared.open(URL(fileURLWithPath: bench.path, isDirectory: true))
    }

    /// Opens Terminal with `benchbar logs` following the bench log. A
    /// `.command` file is a shell script Terminal runs when it opens it, so
    /// this needs no Apple Events permission.
    static func openLogs(_ bench: BenchModel, cli: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BenchBar", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("logs-\(bench.name).command")
        try LogsScript.contents(cli: cli.path, bench: bench.path).write(to: script, atomically: true, encoding: .utf8)
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
