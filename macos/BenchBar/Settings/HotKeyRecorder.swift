import AppKit
import SwiftUI

/// Settings > Labs, under Quick Switch: the key now in use, a button that records the next shortcut
/// pressed (Escape cancels) and a reset to the default.
struct HotKeyRecorder: View {
    let key: QuickSwitchShortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Shortcut") {
                HStack {
                    Button(recording ? "Press the new shortcut…" : key.choice.name) { recording ? stop() : start() }
                        .font(.body.monospaced())
                        .accessibilityLabel(recording ? "Recording a shortcut" : "Quick Switch shortcut \(key.choice.name)")
                    if !key.isDefault && !recording {
                        Button("Reset") { key.reset() }
                    }
                }
            }
            if recording {
                Text("Hold ⌃, ⌥ or ⌘ and press a key. Escape cancels.").font(.caption).foregroundStyle(.secondary)
            }
            if let message = key.message {
                Text(message).font(.callout).foregroundStyle(.red)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let choice = HotKeyChoice.make(keyCode: event.keyCode, flags: event.modifierFlags) {
                key.request(choice)
                stop()
            } else if UInt32(event.keyCode) == HotKeyChoice.cancelKey {
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
