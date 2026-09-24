import AppKit
import SwiftUI

/// Shows the SwiftUI popover under the status item.
final class PopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    /// Tells the store to poll faster while the popover is open.
    var onOpenChange: ((Bool) -> Void)?
    private weak var button: NSStatusBarButton?

    init(rootView: some View) {
        super.init()
        let hosting = NSHostingController(rootView: rootView)
        // the popover follows the SwiftUI view's size as it grows (doctor results)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        // transient: a click anywhere else closes it
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    func toggle(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            show(from: button)
        }
    }

    func show(from button: NSStatusBarButton) {
        self.button = button
        // an accessory app has to activate itself, or the popover never
        // becomes key and its keyboard shortcuts do nothing
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        let window = popover.contentViewController?.view.window
        window?.makeKey()
        // no control starts focused: otherwise Stop gets the focus ring and
        // a stray Space or Return stops the bench. ⌘ shortcuts still work,
        // and Tab still moves focus on purpose.
        window?.makeFirstResponder(nil)
        button.highlight(true)
        onOpenChange?(true)
    }

    func close() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        button?.highlight(false)
        onOpenChange?(false)
    }
}
