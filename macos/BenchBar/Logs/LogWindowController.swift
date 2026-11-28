import AppKit
import SwiftUI

/// One log window per bench, opened with ⌘L from the popover. Like the
/// BenchBar window it turns the app into a regular app while it is open
/// (WindowPresence counts the open windows).
final class LogWindowController: NSObject, NSWindowDelegate {
    private var windows: [String: (NSWindow, LogViewModel)] = [:]
    private let openInTerminal: (String) -> Void
    /// The CLI for the reads that need it (since the last start, the worker log); nil until it is found.
    private let client: () -> CLIClient?

    init(client: @escaping () -> CLIClient? = { nil }, openInTerminal: @escaping (String) -> Void) {
        self.client = client
        self.openInTerminal = openInTerminal
    }

    func show(benchName: String, benchPath: String) {
        if let (window, _) = windows[benchPath] {
            WindowPresence.bringForward(window)
            return
        }
        let model = LogViewModel(benchName: benchName, benchPath: benchPath)
        let client = client
        model.fetch = { request in
            guard let cli = client() else { throw CLIError.failed(command: "logs", exitCode: 1, message: String(localized: "The benchbar command line tool is not available.")) }
            return try await cli.logs(request, bench: benchPath)
        }
        let view = LogView(model: model) { [weak self] in self?.openInTerminal(benchPath) }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = String(localized: "\(benchName): bench.log")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 860, height: 520))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("BenchBarLog-\(benchName)")
        window.center()
        windows[benchPath] = (window, model)
        model.start()
        WindowPresence.opened()
        WindowPresence.bringForward(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = windows.first(where: { $0.value.0 === window }) else { return }
        entry.value.1.stop()
        windows[entry.key] = nil
        WindowPresence.closed()
    }
}

/// BenchBar is an accessory app (no Dock icon); while any of its windows is
/// open it is a regular app, so the window can take focus and ⌘Tab works.
/// Counted, so closing one window does not demote the app while another is open.
enum WindowPresence {
    private static var open = 0

    static func opened() {
        open += 1
        NSApp.setActivationPolicy(.regular)
    }

    static func closed() {
        open = max(0, open - 1)
        if open == 0 { NSApp.setActivationPolicy(.accessory) }
    }

    static func bringForward(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
