import AppKit
import Carbon.HIToolbox
import Observation

/// The Quick Switch shortcut: a physical key (Carbon key code) and Carbon modifier bits.
/// Plain data, so the recorder, the store and the tests need no keyboard.
struct HotKeyChoice: Equatable, Codable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// ⌃⌥ and the key that is U on a US layout.
    static let standard = HotKeyChoice(keyCode: UInt32(kVK_ANSI_U), modifiers: UInt32(controlKey | optionKey))

    /// Keys that carry no letter, named as the keyboard prints them.
    private static let fixedNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Escape cancels a recording, so it is never a shortcut.
    static let cancelKey = UInt32(kVK_Escape)

    /// The choice a key press makes, or nil when it cannot be a system wide shortcut:
    /// it needs ⌃, ⌥ or ⌘ (⇧ alone would take a letter from every app), and Escape cancels.
    static func make(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> HotKeyChoice? {
        guard UInt32(keyCode) != cancelKey else { return nil }
        var bits: UInt32 = 0
        if flags.contains(.control) { bits |= UInt32(controlKey) }
        if flags.contains(.option) { bits |= UInt32(optionKey) }
        if flags.contains(.command) { bits |= UInt32(cmdKey) }
        guard bits != 0 else { return nil }
        if flags.contains(.shift) { bits |= UInt32(shiftKey) }
        return HotKeyChoice(keyCode: UInt32(keyCode), modifiers: bits)
    }

    /// Whether the bits hold a modifier a system wide key may rest on.
    var isUsable: Bool { modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 }

    /// The shortcut as the person reads it: modifiers, then the key by the letter the current
    /// layout shows on it (U on a US keyboard) or its printed name.
    var name: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName
    }

    var keyName: String {
        Self.fixedNames[Int(keyCode)] ?? HotKey.layoutLabel(keyCode: keyCode) ?? "Key \(keyCode)"
    }
}

/// Where the chosen key is kept: one JSON value in UserDefaults.
struct HotKeyStore {
    static let key = "quickSwitchHotKey"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The saved choice; the default when nothing is saved or the value is unusable.
    func load() -> HotKeyChoice {
        guard let data = defaults.data(forKey: Self.key),
              let choice = try? JSONDecoder().decode(HotKeyChoice.self, from: data),
              choice.isUsable else { return .standard }
        return choice
    }

    func save(_ choice: HotKeyChoice) {
        if choice == .standard {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(choice) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// What Settings shows and asks for: the key now in use, the last refusal, and the controller's answer to a request.
@MainActor @Observable
final class QuickSwitchShortcut {
    static let shared = QuickSwitchShortcut()

    private(set) var choice: HotKeyChoice
    /// Why the last request was refused; cleared by the next one.
    private(set) var message: String?
    @ObservationIgnored private let store: HotKeyStore
    /// Set by the controller: tries the key and answers whether it holds.
    @ObservationIgnored var apply: ((HotKeyChoice) -> Bool)?

    init(store: HotKeyStore = HotKeyStore()) {
        self.store = store
        self.choice = store.load()
    }

    /// Asks for a key. A key another app holds shows a message and the old key stays.
    func request(_ wanted: HotKeyChoice) {
        message = nil
        guard wanted != choice else { return }
        let accepted = apply?(wanted) ?? true
        if accepted {
            choice = wanted
            store.save(wanted)
        } else {
            message = "\(wanted.name) is used by another app. \(choice.name) stays."
        }
    }

    func reset() { request(.standard) }
    var isDefault: Bool { choice == .standard }
}
