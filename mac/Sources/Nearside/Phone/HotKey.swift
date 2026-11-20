import Carbon

/// A system-wide keyboard shortcut (Carbon's hot keys: no Accessibility permission needed, and
/// the key press doesn't reach the frontmost app).
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var actions: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1

    /// `keyCode` is a virtual key (kVK_…), `modifiers` Carbon's (cmdKey | optionKey…).
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4154_484B), id: id) // "ATHK"
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else {
            NSLog("Nearside: couldn't register the hot key (taken by another app?)")
            return nil
        }
        Self.actions[id] = action
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.actions[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            MainActor.assumeIsolated { HotKey.actions[id]?() } // delivered on the main thread
            return noErr
        }, 1, &spec, nil, nil)
    }
}
