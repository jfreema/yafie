import Carbon.HIToolbox

/// A shortcut Yafie holds, from HotKeys.register
struct HotKey {
    fileprivate let ref: EventHotKeyRef
    fileprivate let id: UInt32
}

/// Yafie's global shortcuts, through one Carbon handler that hands each press to whatever registered it. A registered
/// keystroke goes to Yafie alone and never reaches the frontmost app.
@MainActor
enum HotKeys {
    nonisolated private static let signature: OSType = 0x5941_4649  // "YAFI"

    private static var actions: [UInt32: @MainActor () -> Void] = [:]
    private static var lastID: UInt32 = 0
    private static var handler: EventHandlerRef?

    /// Nil if another app holds the shortcut
    static func register(_ key: Int, _ modifiers: Int, action: @escaping @MainActor () -> Void) -> HotKey? {
        installHandler()
        lastID += 1
        var ref: EventHotKeyRef?
        guard RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: signature, id: lastID),
                                  GetApplicationEventTarget(), 0, &ref) == noErr, let ref else { return nil }
        actions[lastID] = action
        return HotKey(ref: ref, id: lastID)
    }

    static func unregister(_ hotKey: HotKey) {
        UnregisterEventHotKey(hotKey.ref)
        actions[hotKey.id] = nil
    }

    /// Carbon calls the newest handler first, and the next only when one returns eventNotHandledErr. So this one
    /// passes on any press it didn't register.
    private static func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            guard let event,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == HotKeys.signature else { return OSStatus(eventNotHandledErr) }
            // Carbon calls this on the main thread
            let handled = MainActor.assumeIsolated { HotKeys.pressed(id.id) }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }, 1, &pressed, nil, &handler)
    }

    private static func pressed(_ id: UInt32) -> Bool {
        guard let action = actions[id] else { return false }
        action()
        return true
    }
}
