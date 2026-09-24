import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings?
    private var store: BenchStore?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // the tests run inside this app (TEST_HOST): no menu bar item, no CLI calls
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        let settings = AppSettings()
        let store = BenchStore(settings: settings)
        let controller = StatusItemController(store: store, settings: settings)
        store.onChange = { [weak controller] in controller?.update() }
        statusItemController = controller
        controller.statusItem.menu = makeMenu()
        self.settings = settings
        self.store = store

        Task { await store.start() }
    }

    /// A stand in until the popover (Phase 5): just a way to quit.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit BenchBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }
}
