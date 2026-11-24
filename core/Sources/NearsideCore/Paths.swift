#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum Paths {
    public static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Nearside")
    public static let history = support.appendingPathComponent("history.json")
    static let token = support.appendingPathComponent("token")
}

/// The Mac's secret for the helper (passed to it over adb, never over the network). Stored
/// owner-only.
enum Token {
    /// Names this Mac's token to the helper without revealing it (see the helper's MacTokens).
    static var id: String {
        SHA256.hash(data: Data("nearside-id:\(value)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    static let value: String = {
        if let existing = try? String(contentsOf: Paths.token, encoding: .utf8), existing.count >= 32 {
            return existing
        }
        let token = secureRandomBytes(32).map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Paths.token.path, contents: Data(token.utf8),
                                       attributes: [.posixPermissions: 0o600])
        return token
    }()
}

/// From the system's secure random source on every platform (arc4random_buf, BCryptGenRandom).
func secureRandomBytes(_ count: Int) -> Data {
    var random = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &random) })
}
