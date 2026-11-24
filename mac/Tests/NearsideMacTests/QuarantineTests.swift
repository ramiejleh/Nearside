import Foundation
import NearsideMac
import Testing

@Suite struct QuarantineTests {
    @Test func receivedFilesGetTheQuarantineFlag() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).command")
        try Data("echo hi".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        MacPlatform().markDownloaded(url)
        var buffer = [CChar](repeating: 0, count: 256)
        let length = getxattr(url.path, "com.apple.quarantine", &buffer, buffer.count, 0, 0)
        #expect(length > 0)
        #expect(String(cString: buffer).hasPrefix("0083;"))
    }
}
