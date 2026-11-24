import CNIOBoringSSL
import Foundation
@testable import NativeAdb
import Testing

/// USB auth: adbd checks the signed token with RSA_verify(NID_sha1, token, …) against the keys
/// it trusts (adb's auth.cpp).
@Suite struct USBAuthTests {
    @Test func signedTokenVerifiesAsAdbdChecksIt() throws {
        let key = try AdbKey.generate()
        let token = Data((0..<20).map { UInt8($0 * 7 & 0xFF) })
        let signature = try #require(key.signToken(token))
        #expect(signature.count == 256)
        let rsa = try #require(EVP_PKEY_get0_RSA(key.pkey))
        let ok = token.withUnsafeBytes { t in
            signature.withUnsafeBytes { s in
                RSA_verify(NID_sha1, t.bindMemory(to: UInt8.self).baseAddress, 20,
                           s.bindMemory(to: UInt8.self).baseAddress, s.count, rsa)
            }
        }
        #expect(ok == 1)
    }

    @Test func onlyTwentyByteTokens() throws {
        #expect(try AdbKey.generate().signToken(Data(count: 19)) == nil)
    }
}
