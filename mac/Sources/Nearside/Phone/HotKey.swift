import AppKit
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

/// The launcher's shortcut (Settings → Phone apps), ⌥⌘P unless changed. It must use ⌘ or ⌃, so
/// it can't take over a key people type.
struct LauncherShortcut: Equatable {
    var keyCode: Int
    var modifiers: NSEvent.ModifierFlags
    /// The key as typed without modifiers ("p"), for menus.
    var key: String

    static let `default` = LauncherShortcut(keyCode: kVK_ANSI_P, modifiers: [.command, .option], key: "p")
    static let changed = Notification.Name("LauncherShortcutChanged")
    private static let defaultsKey = "PhoneApps.launcherShortcut"

    static var current: LauncherShortcut {
        get {
            guard let d = UserDefaults.standard.dictionary(forKey: defaultsKey), let code = d["code"] as? Int,
                  let mods = d["mods"] as? UInt, let key = d["key"] as? String, !key.isEmpty else { return .default }
            return LauncherShortcut(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: mods), key: key)
        }
        set {
            UserDefaults.standard.set(["code": newValue.keyCode, "mods": newValue.modifiers.rawValue, "key": newValue.key], forKey: defaultsKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// From a key press, if it can be a shortcut (⌘ or ⌃ with a key that types something).
    init?(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !mods.intersection([.command, .control]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.value >= 0x20 })
        else { return nil }
        self.init(keyCode: Int(event.keyCode), modifiers: mods, key: key)
    }

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    var carbonModifiers: Int {
        (modifiers.contains(.command) ? cmdKey : 0) | (modifiers.contains(.option) ? optionKey : 0)
            | (modifiers.contains(.control) ? controlKey : 0) | (modifiers.contains(.shift) ? shiftKey : 0)
    }

    /// "⌥⌘P", in the order macOS shows modifiers.
    var title: String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + (key == " " ? "Space" : key.uppercased())
    }
}
