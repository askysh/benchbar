import AppKit
import SwiftUI

/// The BenchBar window (settings, benches, apps, sites, profiles).
///
/// BenchBar is an "accessory" app (LSUIElement): no Dock icon, and macOS
/// will not bring its windows to the front. While this window is open the
/// app becomes a regular app (WindowPresence counts the open windows).
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let router = WindowRouter()
    private let makeView: (WindowRouter) -> MainWindowView

    init(makeView: @escaping (WindowRouter) -> MainWindowView) {
        self.makeView = makeView
    }

    func show(_ pane: WindowPane? = nil, tab: BenchTab? = nil, repair: Bool = false) {
        if let pane { router.pane = pane }
        if let tab { router.benchTab = tab }
        if repair { router.repairRequested = true }
        if window == nil {
            let hosting = NSHostingController(rootView: makeView(router))
            // only a minimum: the default also follows the ideal size of each
            // pane, so the window jumped wider on General
            hosting.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "BenchBar"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 860, height: 600))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("BenchBarWindow")
            window.center()
            self.window = window
        }
        if window?.isVisible != true { WindowPresence.opened() }
        if let window { WindowPresence.bringForward(window) }
    }

    func windowWillClose(_ notification: Notification) {
        WindowPresence.closed()
    }
}
