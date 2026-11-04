import AppKit
import SwiftUI

/// A Spotlight-style floating panel. It becomes key (so typing works)
/// without activating BenchBar, so the browser stays the frontmost app.
final class QuickSwitchPanel: NSPanel {
    /// Answers true when it used the key press.
    var onKeyDown: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    init(rootView: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: QuickSwitchView.width + 48, height: 560),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        contentView = NSHostingView(rootView: rootView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Arrows, Return, Escape, Tab and digits are taken here, before the
    /// text field sees them. Scoped to this window, so it needs no permission.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Centred horizontally, in the upper third of the screen the pointer is on.
    func place(onScreenWith pointer: NSPoint) {
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = frame.size
        setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - area.height * 0.18 - size.height))
    }
}

/// What the controller needs of the Carbon key, so a test can refuse it.
protocol HotKeyRegistering: AnyObject {
    @discardableResult func register() -> Bool
    func unregister()
}

extension HotKey: HotKeyRegistering {}

/// Owns the hot key and the panel: ⌃⌥U shows it, or hides it when it is up.
/// Settings > Labs is the one switch (`Labs.isOn(.quickSwitch)`): off, the key is
/// not registered and the panel opens from nowhere.
final class QuickSwitchController {
    static let conflictNote = "⌃⌥U is used by another app, so Quick Switch was turned off. Turn it on again to retry."

    private let store: BenchStore
    private let labs: Labs
    private var hotKey: HotKeyRegistering!
    private var panel: QuickSwitchPanel?
    private var shown = 0

    init(store: BenchStore, labs: Labs, hotKey: HotKeyRegistering? = nil) {
        self.store = store
        self.labs = labs
        self.hotKey = hotKey ?? HotKey { [weak self] in self?.toggle() }
    }

    /// Makes the hot key match the lab. A key another app holds turns the lab
    /// back off (through the CLI too) with a note under its row; the next flip tries again.
    func sync() {
        guard labs.isOn(.quickSwitch) else {
            hotKey.unregister()
            close()
            return
        }
        guard !hotKey.register() else { return }
        Task { [labs] in
            try? await labs.set(.quickSwitch, on: false)
            labs.note(.quickSwitch, Self.conflictNote)
        }
    }

    var isShowing: Bool { panel != nil }

    func toggle() {
        guard labs.isOn(.quickSwitch) else { return close() }
        if panel == nil { show() } else { close() }
    }

    private func makeModel(lastSwitchedKey: String?) -> QuickSwitchModel {
        let benches = store.benches.map { QuickSwitchBench(path: $0.path, running: $0.state == .running, rows: $0.siteRows) }
        return QuickSwitchModel(benches: benches, selectedPath: store.selected?.path, lastSwitchedKey: lastSwitchedKey,
                                pins: store.openAs.pins, recents: store.openAs.recentsBySite,
                                loaded: store.hasLoadedBenches, cliAvailable: store.cliClient != nil)
    }

    private func show() {
        guard labs.isOn(.quickSwitch) else { return }
        let model = makeModel(lastSwitchedKey: store.openAs.lastSwitchedKey)
        shown += 1
        let opening = shown
        let session = QuickSwitchSession(
            model: model,
            switcher: { [weak self] request in await self?.switchUser(request, panelNumber: opening) },
            userSearch: { [weak self] target, query, limit in await self?.findUsers(target, query: query, limit: limit) },
            close: { [weak self] in self?.close() })
        let panel = QuickSwitchPanel(rootView: QuickSwitchView(session: session))
        panel.onKeyDown = { event in Self.press(event, in: session) }
        panel.onResignKey = { [weak self] in self?.close() }
        panel.place(onScreenWith: NSEvent.mouseLocation)
        self.panel = panel
        // not NSApp.activate: the browser has to stay frontmost
        panel.makeKeyAndOrderFront(nil)
        Task { await refreshWhileOpen(session, panelNumber: opening) }
    }

    /// The cached bench states can be old (a bench started from Terminal): ask once, no polling, and
    /// update the panel if the answer changes what it offers.
    private func refreshWhileOpen(_ session: QuickSwitchSession, panelNumber: Int) async {
        if store.hasLoadedBenches { await store.refreshAll() } else { await store.reloadBenches() }
        guard panel != nil, shown == panelNumber else { return }
        session.refresh(with: makeModel(lastSwitchedKey: session.model.target?.id ?? store.openAs.lastSwitchedKey))
    }

    private func close() {
        guard let panel else { return }
        self.panel = nil
        panel.onResignKey = nil
        panel.orderOut(nil)
    }

    private static func press(_ event: NSEvent, in session: QuickSwitchSession) -> Bool {
        let key = session.model.key(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                    hasModifier: !event.modifierFlags.intersection([.command, .control, .option]).isEmpty)
        guard let key else { return false }
        session.press(key)
        return true
    }

    /// The error text, nil on success. After the panel has closed, a failure
    /// is left on the bench for the popover to show; while it is open, the
    /// panel shows it inline instead.
    private func switchUser(_ request: QuickSwitchRequest, panelNumber: Int) async -> String? {
        guard let bench = store.benches.first(where: { $0.path == request.target.bench }),
              let row = bench.siteRows.first(where: { $0.name == request.target.site }) else {
            return "That site is no longer available."
        }
        if store.openAs.isSwitching(bench: bench.path, site: row.name) { return QuickSwitchModel.alreadySwitchingCopy }
        let error = await store.switchUser(request.user, fullName: request.fullName, on: bench, row: row)
        guard panel != nil, shown == panelNumber, let error else { return nil }
        if bench.lastError == error { bench.lastError = nil }
        return error
    }

    private func findUsers(_ target: QuickSwitchTarget, query: String, limit: Int) async -> [SiteUser]? {
        guard let client = store.cliClient else { return nil }
        do throws(CLIError) {
            return try await client.users(bench: target.bench, site: target.site, search: query, limit: limit).users
        } catch {
            return nil
        }
    }
}
