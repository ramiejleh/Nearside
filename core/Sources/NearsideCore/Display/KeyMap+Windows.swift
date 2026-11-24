/// What a Windows keystroke does in a phone window (pure, so it's tested). As on the Mac, text is
/// never mapped here: it arrives as characters through Windows' own input (layouts, dead keys,
/// AltGr, IMEs, the emoji panel). Windows' editing shortcuts are Android's already (Ctrl+← by
/// word, Home/End, Ctrl+C/V/X/Z/A), so keys and modifiers pass through as they are.
extension KeyMap {
    public struct WindowsModifiers: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let shift = WindowsModifiers(rawValue: 1), control = WindowsModifiers(rawValue: 2)
        public static let alt = WindowsModifiers(rawValue: 4)
    }

    /// Windows virtual-key codes (VK_…) that aren't text → Android key codes.
    static let windowsNonText: [UInt16: UInt16] = [
        0x0D: 66, // Enter
        0x09: 61, // Tab
        0x08: del, // Backspace
        0x2E: forwardDel, // Delete
        0x1B: 111, // Escape
        0x24: home, 0x23: end, 0x21: 92, 0x22: 93, // Home, End, Page Up, Page Down
        0x25: left, 0x27: right, 0x28: down, 0x26: up,
        0x70: 131, 0x71: 132, 0x72: 133, 0x73: 134, 0x74: 135, 0x75: 136, // F1–F6
        0x76: 137, 0x77: 138, 0x78: 139, 0x79: 140, 0x7A: 141, 0x7B: 142, // F7–F12
    ]

    /// VK_A…VK_Z, VK_0…VK_9 and the punctuation keys a shortcut can use → Android key codes.
    static func windowsShortcutKey(_ vk: UInt16) -> UInt16? {
        switch vk {
        case 0x41...0x5A: return 29 + vk - 0x41
        case 0x30...0x39: return 7 + vk - 0x30
        case 0x20: return 62 // Space
        case 0xBD: return 69 // -
        case 0xBB: return 70 // =
        case 0xDB: return 71 // [
        case 0xDD: return 72 // ]
        case 0xDC: return 73 // \
        case 0xBA: return 74 // ;
        case 0xDE: return 75 // '
        case 0xBF: return 76 // /
        case 0xBE: return 56 // .
        default: return nil
        }
    }

    public static func windowsAction(virtualKey vk: UInt16, modifiers m: WindowsModifiers) -> Action {
        let meta = (m.contains(.shift) ? shift : 0) | (m.contains(.control) ? ctrl : 0) | (m.contains(.alt) ? alt : 0)
        // AltGr arrives as Ctrl+Alt: with a character key it types (é, @, €), so it's text.
        let altGr = m.contains(.control) && m.contains(.alt)
        if let code = windowsNonText[vk] { return .keys([Key(code, meta)]) }
        if m.contains(.control) && !altGr {
            if vk == 0x56 && m == .control { return .paste } // Ctrl+V: this PC's clipboard
            if let code = windowsShortcutKey(vk) { return .keys([Key(code, meta)]) }
            return .none
        }
        return .text
    }
}
