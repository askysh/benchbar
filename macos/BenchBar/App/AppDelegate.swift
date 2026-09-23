import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "figure.run", accessibilityDescription: "BenchBar")
        image?.isTemplate = true
        item.button?.image = image
        statusItem = item
    }
}
