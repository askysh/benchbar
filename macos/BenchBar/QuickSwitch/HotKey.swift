import Carbon.HIToolbox

/// ⌃⌥ and the key that is U on a US layout, system wide, through Carbon's `RegisterEventHotKey`. Unlike an
/// `NSEvent` global monitor it needs no Accessibility permission, and the
/// system keeps the key for this app alone: a second claimant fails instead
/// of both firing.
final class HotKey {
    private static let signature: OSType = 0x4242_5153 // 'BBQS'
    /// The physical key (a position, not a letter), and its modifiers.
    static let keyCode = UInt32(kVK_ANSI_U)
    static let modifiers = UInt32(controlKey | optionKey)

    /// The shortcut as the person reads it on their keyboard: ⌃⌥ and the
    /// letter that key carries in the current layout (U on a US keyboard).
    static var name: String { "⌃⌥" + keyLabel() }

    /// The character the key produces without modifiers in the current
    /// layout, upper case. "U" when the layout cannot be read.
    static func keyLabel(keyCode: UInt32 = HotKey.keyCode) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "U" }
        let data = unsafeBitCast(raw, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return "U" }
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "U" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    var isRegistered: Bool { hotKeyRef != nil }

    /// False when the key is taken (or the handler cannot be installed): the
    /// caller says so and keeps the setting; the next `sync` tries again.
    @discardableResult
    func register() -> Bool {
        guard hotKeyRef == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, context, &handlerRef) == noErr else {
            return false
        }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(Self.keyCode, Self.modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            removeHandler()
            hotKeyRef = nil
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        removeHandler()
    }

    fileprivate func pressed() {
        onPress()
    }

    private func removeHandler() {
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}

/// Carbon calls this from the C event loop, so it is not MainActor. Hot key
/// events are delivered through the application event target on the main
/// thread's run loop, which is what makes `assumeIsolated` true here; it
/// traps if that ever stops holding rather than racing silently. The
/// handler is removed with the hot key, so `context` outlives every call.
private nonisolated func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                       _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let context else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.pressed() }
    return noErr
}
