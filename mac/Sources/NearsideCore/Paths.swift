import CryptoKit
import Foundation
import Security

public enum Paths {
    public static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Nearside")
    public static let history = support.appendingPathComponent("history.json")
    static let token = support.appendingPathComponent("token")
}

/// The Mac's secret for the helper (passed as its env var over adb, then sent back through the
/// adb tunnel). Stored owner-only. Shared with the PoC CLI so an existing pairing keeps working.
enum Token {
    /// Names this Mac's token to the helper without revealing it (see the helper's MacTokens).
    static var id: String {
        SHA256.hash(data: Data("nearside-id:\(value)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    static let value: String = {
        if let existing = try? String(contentsOf: Paths.token, encoding: .utf8), existing.count >= 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Paths.token.path, contents: Data(token.utf8),
                                       attributes: [.posixPermissions: 0o600])
        return token
    }()
}
