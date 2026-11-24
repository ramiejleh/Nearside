#if os(Windows)
@testable import NearsideCore
import Testing

/// Names from the phone that would be dangerous or rewritten on Windows.
@Suite struct WindowsFileNameTests {
    @Test func noFoldersNoReservedCharacters() {
        #expect(FileNames.safe("..\\..\\Startup\\run.bat") == "run.bat")
        #expect(FileNames.safe("a<b>c:d\"e|f?g*h.txt") == "abcdefgh.txt")
    }

    @Test func noTrailingDotsOrSpaces() {
        #expect(FileNames.safe("invoice.pdf.exe. . ") == "invoice.pdf.exe")
    }

    @Test func noDeviceNames() {
        #expect(FileNames.safe("CON") == "_CON")
        #expect(FileNames.safe("nul.txt") == "_nul.txt")
        #expect(FileNames.safe("COM3.log") == "_COM3.log")
        #expect(FileNames.safe("COMPUTER.txt") == "COMPUTER.txt")
    }
}
#endif
