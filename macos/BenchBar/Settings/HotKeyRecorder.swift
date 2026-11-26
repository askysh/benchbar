import AppKit
import SwiftUI

/// Settings > Labs, under Quick Switch: the key now in use, a button that records the next shortcut
/// pressed (Escape cancels) and a reset to the default.
///
/// While it listens the current key is let go (`QuickSwitchShortcut.beginRecording`), so pressing it
/// records it instead of opening the panel. Every way out ends in `stop`: a key, Escape, the window losing
/// focus or closing, and the row going away (the lab turned off).
struct HotKeyRecorder: View {
    let key: QuickSwitchShortcut
    @State private var recording = false
    @State private var session = RecorderSession()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Shortcut") {
                HStack {
                    Button(recording ? String(localized: "Press the new shortcut…") : key.choice.name) { recording ? stop() : start() }
                        .font(.body.monospaced())
                        .accessibilityLabel(recording ? String(localized: "Recording a shortcut") : String(localized: "Quick Switch shortcut \(key.choice.name)"))
                    if !key.isDefault && !recording {
                        Button("Reset") { key.reset() }
                    }
                }
            }
            if recording {
                Text("Hold ⌃ or ⌥ and press a key. Escape cancels.").font(.caption).foregroundStyle(.secondary)
            }
            if let message = key.message {
                Text(message).font(.callout).foregroundStyle(.red)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        guard let window = NSApp.keyWindow else { return }
        key.beginRecording()
        recording = true
        session.begin(window: window, key: key, onStop: stop)
    }

    private func stop() {
        session.end()
        recording = false
        key.endRecording()
    }
}

/// The listeners of one recording: a key monitor for the Settings window only, and the window's
/// losing focus or closing.
@MainActor final class RecorderSession {
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    func begin(window: NSWindow, key: QuickSwitchShortcut, onStop: @escaping @MainActor () -> Void) {
        end()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // another window's keys are not ours; a press `make` refuses goes on its way
            guard event.window === window else { return event }
            let keyCode = event.keyCode, flags = event.modifierFlags
            let swallowed: Bool = MainActor.assumeIsolated {
                if UInt32(keyCode) == HotKeyChoice.cancelKey {
                    onStop()
                    return true
                }
                guard let choice = HotKeyChoice.make(keyCode: keyCode, flags: flags) else {
                    key.refuse(String(localized: "A shortcut needs ⌃ or ⌥ (⌘ and ⇧ can come with them)."))
                    return false
                }
                key.request(choice)
                onStop()
                return true
            }
            return swallowed ? nil : event
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { onStop() }
            })
        }
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
