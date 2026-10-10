import AppKit
import Observation
import SwiftUI

/// The tabs of the Settings window.
enum SettingsTab: Hashable {
    case general, menuBar
}

@Observable
final class SettingsTabs {
    var selected: SettingsTab = .general
}

/// What the Settings window shows: General and Menu Bar, as tabs.
struct SettingsTabsView: View {
    @Bindable var tabs: SettingsTabs
    let general: SettingsView
    let menuBar: SettingsView

    static let size = CGSize(width: 560, height: 560)

    var body: some View {
        TabView(selection: $tabs.selected) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            menuBar.tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }.tag(SettingsTab.menuBar)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// The compact Settings window (⌘,): General and Menu Bar. The BenchBar
/// window is the app's home; its settings used to live in it, and these two
/// tabs are what is left of that, in a window of their own as in 0.4.
///
/// Like the other windows it makes BenchBar a regular app while it is open
/// (WindowPresence counts them).
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    /// Help > Keyboard Shortcuts scrolls General to its shortcuts through this.
    let router = WindowRouter()
    let tabs = SettingsTabs()
    private let makeView: (SettingsTabs, WindowRouter) -> SettingsTabsView

    init(makeView: @escaping (SettingsTabs, WindowRouter) -> SettingsTabsView) {
        self.makeView = makeView
    }

    func show(_ tab: SettingsTab? = nil) {
        if let tab { tabs.selected = tab }
        if window == nil {
            let hosting = NSHostingController(rootView: makeView(tabs, router))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "BenchBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        if window?.isVisible != true { WindowPresence.opened() }
        if let window { WindowPresence.bringForward(window) }
    }

    var isOpen: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        WindowPresence.closed()
    }
}
