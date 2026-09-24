import AppKit
import SwiftUI

/// The Settings window of a menu bar app.
///
/// BenchBar is an "accessory" app (LSUIElement): no Dock icon, and macOS
/// will not bring its windows to the front. The known working pattern:
/// switch the activation policy to .regular while the window is open, so it
/// behaves like a normal window (Dock icon, ⌘Tab, focus), and back to
/// .accessory when it closes.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeView: () -> SettingsView

    init(makeView: @escaping () -> SettingsView) {
        self.makeView = makeView
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: makeView())
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "BenchBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
