/// What a Mac keystroke does in a phone-app window (pure, so it's tested).
///
/// Text is never mapped here: it goes through the Mac's own text input (its layout, dead keys,
/// input methods, the emoji picker) and reaches the phone as characters. This maps what isn't
/// text: editing and navigation keys, and shortcuts, translated to what Android does with them, so
/// they behave the way they would on the Mac (⌘← line start, ⌥← word, ⌘⌫ delete to line start,
/// ⌘C/V/X/Z/A/F… as Ctrl).
public enum KeyMap {
    public enum Action: Equatable, Sendable {
        /// Let the Mac's text input handle it (it becomes text, or nothing).
        case text
        /// Android key presses, in order: (key code, meta state).
        case keys([Key])
        /// ⌘V: the Mac's clipboard, pasted.
        case paste
        case back
        /// A Mac shortcut (⌘W, ⌘Q, ⌘H, ⌘M, ⌘`, ⌘,): not the phone's.
        case mac
        case none
    }

    public struct Key: Equatable, Sendable {
        public let code: UInt16
        public let meta: UInt32
        public init(_ code: UInt16, _ meta: UInt32 = 0) { self.code = code; self.meta = meta }
    }

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1), control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4), command = Modifiers(rawValue: 8)
    }

    // Android KeyEvent meta states (the side-specific bit too, as a real keyboard sets them).
    static let shift: UInt32 = 0x01 | 0x40, alt: UInt32 = 0x02 | 0x10, ctrl: UInt32 = 0x1000 | 0x2000

    // Android key codes.
    static let up: UInt16 = 19, down: UInt16 = 20, left: UInt16 = 21, right: UInt16 = 22
    static let del: UInt16 = 67, forwardDel: UInt16 = 112, home: UInt16 = 122, end: UInt16 = 123

    /// Keys that aren't text: macOS virtual key code (kVK_…) → Android key code.
    static let nonText: [UInt16: UInt16] = [
        0x24: 66, // Return → ENTER
        0x4C: 160, // keypad Enter → NUMPAD_ENTER
        0x30: 61, // Tab
        0x33: del, // Delete (backspace) → DEL
        0x75: forwardDel,
        0x35: 111, // Escape (Android falls back to Back when the app doesn't use it)
        0x73: home, 0x77: end, 0x74: 92, 0x79: 93, // Home, End, Page Up, Page Down
        0x7B: left, 0x7C: right, 0x7D: down, 0x7E: up,
        0x7A: 131, 0x78: 132, 0x63: 133, 0x76: 134, 0x60: 135, 0x61: 136, // F1–F6
        0x62: 137, 0x64: 138, 0x65: 139, 0x6D: 140, 0x67: 141, 0x6F: 142, // F7–F12
    ]

    /// Characters a shortcut can name (from charactersIgnoringModifiers) → Android key code.
    static func shortcutKey(_ c: Character) -> UInt16? {
        if let a = c.asciiValue {
            switch a {
            case 97...122: return UInt16(29 + a - 97) // a–z → KEYCODE_A…
            case 48...57: return UInt16(7 + a - 48) // 0–9
            default: break
            }
        }
        let symbols: [Character: UInt16] = ["-": 69, "=": 70, "+": 81, "[": 71, "]": 72, "\\": 73, ";": 74,
                                            "'": 75, "/": 76, ".": 56, " ": 62]
        return symbols[c]
    }

    static let reservedForMac: Set<Character> = ["w", "q", "h", "m", "`", ","]

    public static func action(keyCode: UInt16, modifiers m: Modifiers, characters: String?) -> Action {
        let c = characters?.lowercased().first
        let shiftMeta = m.contains(.shift) ? shift : 0
        if m.contains(.command) {
            if let c, reservedForMac.contains(c) { return .mac }
            if keyCode == 0x21, m == .command { return .back } // ⌘[
            switch keyCode {
            case 0x7B: return .keys([Key(home, shiftMeta)]) // ⌘← line start
            case 0x7C: return .keys([Key(end, shiftMeta)])
            case 0x7E: return .keys([Key(home, ctrl | shiftMeta)]) // ⌘↑ top
            case 0x7D: return .keys([Key(end, ctrl | shiftMeta)])
            case 0x33: return .keys([Key(home, shift), Key(del)]) // ⌘⌫ delete to line start
            default: break
            }
            if c == "v", m == .command { return .paste }
            let meta = ctrl | shiftMeta | (m.contains(.option) ? alt : 0)
            if let code = nonText[keyCode] { return .keys([Key(code, meta)]) }
            if let c, let code = shortcutKey(c) { return .keys([Key(code, meta)]) }
            return .none
        }
        if m.contains(.control) {
            let meta = ctrl | shiftMeta | (m.contains(.option) ? alt : 0)
            if let code = nonText[keyCode] { return .keys([Key(code, meta)]) }
            if let c, let code = shortcutKey(c) { return .keys([Key(code, meta)]) }
            return .none
        }
        guard let code = nonText[keyCode] else { return .text }
        if m.contains(.option) {
            switch code {
            case left, right, up, down, del, forwardDel: return .keys([Key(code, ctrl | shiftMeta)]) // ⌥ = by word
            default: return .keys([Key(code, alt | shiftMeta)])
            }
        }
        return .keys([Key(code, shiftMeta)])
    }
}
