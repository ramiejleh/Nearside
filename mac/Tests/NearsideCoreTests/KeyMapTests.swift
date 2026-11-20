import Testing
@testable import NearsideCore

struct KeyMapTests {
    typealias K = KeyMap.Key
    func action(_ code: UInt16, _ m: KeyMap.Modifiers = [], _ c: String? = nil) -> KeyMap.Action {
        KeyMap.action(keyCode: code, modifiers: m, characters: c)
    }

    @Test func lettersAndSymbolsAreText() {
        #expect(action(0x00, [], "a") == .text)
        #expect(action(0x00, .shift, "A") == .text)
        // ⌥ makes characters on Mac layouts (Danish ⌥' = @): the Mac's text input decides.
        #expect(action(0x27, .option, "'") == .text)
        #expect(action(0x31, [], " ") == .text)
    }

    @Test func editingKeysAreAndroidKeys() {
        #expect(action(0x24) == .keys([K(66)])) // Return
        #expect(action(0x33) == .keys([K(67)])) // ⌫ → DEL
        #expect(action(0x7B, .shift) == .keys([K(21, KeyMap.shift)])) // ⇧← selects
        #expect(action(0x35) == .keys([K(111)])) // Escape
    }

    @Test func macTextNavigationBehavesLikeTheMac() {
        #expect(action(0x7B, .command) == .keys([K(122)])) // ⌘← line start
        #expect(action(0x7C, [.command, .shift]) == .keys([K(123, KeyMap.shift)])) // ⌘⇧→ select to end
        #expect(action(0x7E, .command) == .keys([K(122, KeyMap.ctrl)])) // ⌘↑ top
        #expect(action(0x7B, .option) == .keys([K(21, KeyMap.ctrl)])) // ⌥← word
        #expect(action(0x33, .option) == .keys([K(67, KeyMap.ctrl)])) // ⌥⌫ word
        #expect(action(0x33, .command) == .keys([K(122, KeyMap.shift), K(67)])) // ⌘⌫ to line start
    }

    @Test func commandShortcutsAreControl() {
        #expect(action(0x08, .command, "c") == .keys([K(31, KeyMap.ctrl)]))
        #expect(action(0x06, [.command, .shift], "Z") == .keys([K(54, KeyMap.ctrl | KeyMap.shift)])) // redo
        #expect(action(0x09, .command, "v") == .paste)
        #expect(action(0x24, .command) == .keys([K(66, KeyMap.ctrl)])) // ⌘Return
        #expect(action(0x21, .command, "å") == .back) // ⌘[ by position (Danish: å)
    }

    @Test func macShortcutsStayOnTheMac() {
        for c in ["w", "q", "h", "m", "`", ","] { #expect(action(0x0D, .command, c) == .mac) }
        #expect(action(0x04, [.command, .option], "h") == .mac) // hide others
    }

    @Test func controlPassesThrough() {
        #expect(action(0x30, .control) == .keys([K(61, KeyMap.ctrl)])) // ⌃Tab
        #expect(action(0x00, .control, "a") == .keys([K(29, KeyMap.ctrl)]))
    }
}
