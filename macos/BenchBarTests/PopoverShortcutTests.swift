import AppKit
import SwiftUI
import Testing
@testable import BenchBar

/// The popover's ⌘ shortcuts act on the bench the picker shows. SwiftUI kept
/// the shortcuts of the bench first shown when the picker changed bench, so
/// ⌘D stopped the first bench while the second was on screen.
@Suite("Popover shortcuts", .serialized)
struct PopoverShortcutTests {
    let base: BenchStoreTests

    init() throws { base = try BenchStoreTests() }

    static let first = "/Users/you/frappe-bench"
    static let second = "/Users/you/dev/v16-bench"

    @Test func stopActsOnTheSelectedBench() async throws {
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", json: base.runningJSON())
        base.cli.answer("down", .ok("[OK] stopped"))
        let store = base.makeStore()
        await store.start(polling: false)
        store.selectedPath = Self.first
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 370, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PopoverView(store: store, commands: AppCommands()))
        await layOut(window)

        store.selectedPath = Self.second
        await layOut(window)
        #expect(try press("d", keyCode: 2, in: window))
        await base.settle()
        #expect(downs() == [Self.second])

        store.selectedPath = Self.first
        await layOut(window)
        #expect(try press("d", keyCode: 2, in: window))
        await base.settle()
        #expect(downs() == [Self.second, Self.first])
    }

    private func downs() -> [String] {
        base.cli.calls.filter { $0.first == "down" }.compactMap { $0.last }
    }

    private func layOut(_ window: NSWindow) async {
        window.contentView?.layoutSubtreeIfNeeded()
        await base.settle()
    }

    private func press(_ key: String, keyCode: UInt16, in window: NSWindow) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: key,
                                                  charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode))
        return window.performKeyEquivalent(with: event)
    }
}
