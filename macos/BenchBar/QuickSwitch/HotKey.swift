import Carbon.HIToolbox

/// ⌃⌥U, system wide, through Carbon's `RegisterEventHotKey`. Unlike an
/// `NSEvent` global monitor it needs no Accessibility permission, and the
/// system keeps the key for this app alone: a second claimant fails instead
/// of both firing.
final class HotKey {
    private static let signature: OSType = 0x4242_5153 // 'BBQS'

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    var isRegistered: Bool { hotKeyRef != nil }

    /// False when the key is taken (or the handler cannot be installed): the
    /// caller turns the feature off and says so, it does not retry.
    @discardableResult
    func register() -> Bool {
        guard hotKeyRef == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, context, &handlerRef) == noErr else {
            return false
        }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_U), UInt32(controlKey | optionKey), id,
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
