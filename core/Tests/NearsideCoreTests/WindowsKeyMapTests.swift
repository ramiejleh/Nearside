import Testing
@testable import NearsideCore

@Suite struct WindowsKeyMapTests {
    typealias M = KeyMap.WindowsModifiers

    @Test func lettersAndDigitsAreText() {
        #expect(KeyMap.windowsAction(virtualKey: 0x41, modifiers: []) == .text)
        #expect(KeyMap.windowsAction(virtualKey: 0x41, modifiers: .shift) == .text)
        #expect(KeyMap.windowsAction(virtualKey: 0x32, modifiers: []) == .text)
    }

    @Test func altGrTypes() {
        // AltGr+2 is "@" on many layouts: Windows reports it as Ctrl+Alt+2.
        #expect(KeyMap.windowsAction(virtualKey: 0x32, modifiers: [.control, .alt]) == .text)
    }

    @Test func editingKeysPassThroughWithModifiers() {
        #expect(KeyMap.windowsAction(virtualKey: 0x0D, modifiers: []) == .keys([.init(66)]))
        #expect(KeyMap.windowsAction(virtualKey: 0x08, modifiers: []) == .keys([.init(67)]))
        #expect(KeyMap.windowsAction(virtualKey: 0x25, modifiers: .control) == .keys([.init(21, KeyMap.ctrl)]))
        #expect(KeyMap.windowsAction(virtualKey: 0x27, modifiers: [.control, .shift]) == .keys([.init(22, KeyMap.ctrl | KeyMap.shift)]))
        #expect(KeyMap.windowsAction(virtualKey: 0x24, modifiers: .shift) == .keys([.init(122, KeyMap.shift)]))
    }

    @Test func shortcutsAreCtrlKeys() {
        #expect(KeyMap.windowsAction(virtualKey: 0x43, modifiers: .control) == .keys([.init(31, KeyMap.ctrl)])) // Ctrl+C
        #expect(KeyMap.windowsAction(virtualKey: 0x5A, modifiers: [.control, .shift]) == .keys([.init(54, KeyMap.ctrl | KeyMap.shift)]))
        #expect(KeyMap.windowsAction(virtualKey: 0xA0, modifiers: .control) == .none) // Ctrl+Shift key alone
    }

    @Test func ctrlVPastesThisPCsClipboard() {
        #expect(KeyMap.windowsAction(virtualKey: 0x56, modifiers: .control) == .paste)
        #expect(KeyMap.windowsAction(virtualKey: 0x56, modifiers: [.control, .shift]) == .keys([.init(50, KeyMap.ctrl | KeyMap.shift)]))
    }
}

@Suite struct IconCacheNameTests {
    @Test func namesStayInTheirFolder() {
        #expect(PhoneIconCache.name(id: "com.example/com.example.Main", version: 3, adaptive: true) == "com.example~com.example.Main@3.a.png")
        #expect(PhoneIconCache.stem("..\\..\\evil") == "..%5C..%5Cevil")
        #expect(PhoneIconCache.stem("a:b") == "a%3Ab")
        #expect(!PhoneIconCache.name(id: "../x", version: 1, adaptive: false).contains("/"))
    }
}
