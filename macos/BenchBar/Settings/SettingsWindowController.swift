import AppKit
import Observation
import SwiftUI

/// The BenchBar window (settings, benches, apps, sites, profiles).
///
/// BenchBar is an "accessory" app (LSUIElement): no Dock icon, and macOS
/// will not bring its windows to the front. While this window is open the
/// app becomes a regular app (WindowPresence counts the open windows).
///
/// The window is kept when closed (`isReleasedWhenClosed = false`), and its
/// SwiftUI views with it: they never see onDisappear on a close. So the
/// store hears of the window from here (`onSight`): open, close, occlusion
/// (minimized, covered, another Space) and the page shown.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let router = WindowRouter()
    private let makeView: (WindowRouter) -> MainWindowView
    /// Shown and not closed since (a minimized window stays open).
    private var isShown = false
    /// Every change of what the store should know; the store ignores repeats.
    var onSight: ((WindowSight) -> Void)?

    init(makeView: @escaping (WindowRouter) -> MainWindowView) {
        self.makeView = makeView
        super.init()
        observeRouter()
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
        isShown = true
        report()
    }

    func windowWillClose(_ notification: Notification) {
        WindowPresence.closed()
        isShown = false
        report()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        report()
    }

    /// Tells the store what it needs: is the window open, can any of it be
    /// seen, and which bench's Overview (with the charts) does it show.
    private func report() {
        let visible = isShown && window?.occlusionState.contains(.visible) == true
        var overview: String?
        if case .bench(let path) = router.pane, router.benchTab == .overview { overview = path }
        onSight?(WindowSight(isOpen: isShown, isVisible: visible, overview: overview))
    }

    /// The page shown decides which bench's charts sample. Observation fires
    /// once per registration, so it registers again each time.
    private func observeRouter() {
        withObservationTracking {
            _ = router.pane
            _ = router.benchTab
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.report()
                self?.observeRouter()
            }
        }
    }
}
