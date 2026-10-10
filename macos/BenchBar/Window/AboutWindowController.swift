import AppKit
import SwiftUI

/// About BenchBar, in a small window of its own (the app menu's first item).
/// It hosts the About pane: the versions, Check for Updates, the links and
/// Report a Bug. The Help menu and Check for Updates reach it through
/// `router`, whose flags the pane turns into the bug report sheet and the
/// update check.
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let router = WindowRouter()
    private let makeView: (WindowRouter) -> AboutPane

    static let size = CGSize(width: 560, height: 640)

    init(makeView: @escaping (WindowRouter) -> AboutPane) {
        self.makeView = makeView
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: makeView(router).frame(width: Self.size.width, height: Self.size.height))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "About BenchBar"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
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
