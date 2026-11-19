import CNIOBoringSSL
import Foundation

/// The Mac's adb identity: an RSA key (the same `~/.android/adbkey` stock adb uses, so
/// existing pairings keep working) and the self-signed certificate adb wraps it in for TLS.
/// Mirrors AOSP adb's crypto/x509_generator.cpp.
public final class AdbKey: @unchecked Sendable {
    let pkey: OpaquePointer // EVP_PKEY*
    let certificate: OpaquePointer // X509*

    public enum Failure: Error { case unreadable(String), certificate }

    /// Stock adb's key, if this Mac has one.
    public static var defaultPath: String { NSHomeDirectory() + "/.android/adbkey" }

    public convenience init(pemFile path: String) throws {
        guard let pem = FileManager.default.contents(atPath: path) else { throw Failure.unreadable(path) }
        try self.init(pem: pem)
    }

    public init(pem: Data) throws {
        let key: OpaquePointer? = pem.withUnsafeBytes { raw in
            let bio = BIO_new_mem_buf(raw.baseAddress, Int(raw.count))
            defer { BIO_free(bio) }
            return PEM_read_bio_PrivateKey(bio, nil, nil, nil)
        }
        guard let key else { throw Failure.unreadable("not a PEM private key") }
        guard let cert = Self.makeCertificate(key) else {
            EVP_PKEY_free(key)
            throw Failure.certificate
        }
        pkey = key
        certificate = cert
    }

    deinit {
        X509_free(certificate)
        EVP_PKEY_free(pkey)
    }

    /// A new 2048-bit RSA key (e = 65537), as adb makes on first run.
    public static func generate() throws -> AdbKey {
        guard let rsa = RSA_new(), let e = BN_new() else { throw Failure.certificate }
        defer { BN_free(e) }
        guard BN_set_word(e, 65537) == 1, RSA_generate_key_ex(rsa, 2048, e, nil) == 1,
              let key = EVP_PKEY_new(), EVP_PKEY_assign_RSA(key, rsa) == 1 else {
            RSA_free(rsa)
            throw Failure.certificate
        }
        defer { EVP_PKEY_free(key) }
        return try AdbKey(pem: try pem(of: key))
    }

    /// The private key as PKCS#8 PEM ("BEGIN PRIVATE KEY"), the format of ~/.android/adbkey.
    public func pemData() throws -> Data { try Self.pem(of: pkey) }

    private static func pem(of key: OpaquePointer) throws -> Data {
        guard let bio = BIO_new(BIO_s_mem()) else { throw Failure.certificate }
        defer { BIO_free(bio) }
        guard PEM_write_bio_PrivateKey(bio, key, nil, nil, 0, nil, nil) == 1 else { throw Failure.certificate }
        var pointer: UnsafePointer<UInt8>?
        var length = 0
        guard BIO_mem_contents(bio, &pointer, &length) == 1, let pointer else { throw Failure.certificate }
        return Data(bytes: pointer, count: length)
    }

    /// The public key in Android's format, as in adbkey.pub and as sent when pairing:
    /// base64 of { u32 words, u32 n0inv, modulus LE, R² mod n LE, u32 exponent } + " user@host".
    /// Mirrors AOSP libcrypto_utils android_pubkey_encode.
    public func androidPublicKey(comment: String) throws -> String {
        guard let rsa = EVP_PKEY_get0_RSA(pkey), RSA_size(rsa) == 256,
              let ctx = BN_CTX_new(), let r32 = BN_new(), let n0inv = BN_new(), let rr = BN_new() else {
            throw Failure.certificate
        }
        defer { BN_free(rr); BN_free(n0inv); BN_free(r32); BN_CTX_free(ctx) }
        let n = RSA_get0_n(rsa)
        var modulus = [UInt8](repeating: 0, count: 256)
        var rrBytes = [UInt8](repeating: 0, count: 256)
        guard BN_set_bit(r32, 32) == 1, BN_div(nil, n0inv, n, r32, ctx) == 1,
              BN_mod_inverse(n0inv, n0inv, r32, ctx) != nil, BN_sub(n0inv, r32, n0inv) == 1,
              BN_bn2le_padded(&modulus, 256, n) == 1,
              BN_set_bit(rr, 256 * 8) == 1, BN_mod_sqr(rr, rr, n, ctx) == 1,
              BN_bn2le_padded(&rrBytes, 256, rr) == 1 else { throw Failure.certificate }
        var blob = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { blob.append(contentsOf: $0) } }
        u32(64) // modulus size in 32-bit words
        u32(UInt32(truncatingIfNeeded: BN_get_word(n0inv)))
        blob.append(contentsOf: modulus)
        blob.append(contentsOf: rrBytes)
        u32(UInt32(truncatingIfNeeded: BN_get_word(RSA_get0_e(rsa))))
        return blob.base64EncodedString() + " " + comment
    }

    /// C=US, O=Android, CN=Adb, self-signed, 10 years: what adb sends. adbd only checks that
    /// the public key is one it was paired with.
    private static func makeCertificate(_ key: OpaquePointer) -> OpaquePointer? {
        guard let x509 = X509_new() else { return nil }
        var ok = X509_set_version(x509, 2) == 1
        ok = ok && ASN1_INTEGER_set(X509_get_serialNumber(x509), 1) == 1
        ok = ok && X509_gmtime_adj(X509_getm_notBefore(x509), 0) != nil
        ok = ok && X509_gmtime_adj(X509_getm_notAfter(x509), 10 * 365 * 24 * 3600) != nil
        ok = ok && X509_set_pubkey(x509, key) == 1
        let name = X509_get_subject_name(x509)
        for (field, value) in [("C", "US"), ("O", "Android"), ("CN", "Adb")] {
            ok = ok && X509_NAME_add_entry_by_txt(name, field, MBSTRING_ASC, value, -1, -1, 0) == 1
        }
        ok = ok && X509_set_issuer_name(x509, name) == 1
        ok = ok && X509_sign(x509, key, EVP_sha256()) > 0
        if !ok {
            X509_free(x509)
            return nil
        }
        return x509
    }
}

/// SHA-256 of a certificate's public key (SubjectPublicKeyInfo, DER): stable across the
/// phone re-issuing its certificate with the same key.
func publicKeySHA256(_ x509: OpaquePointer) -> Data? {
    guard let key = X509_get_pubkey(x509) else { return nil }
    defer { EVP_PKEY_free(key) }
    var der: UnsafeMutablePointer<UInt8>?
    let length = i2d_PUBKEY(key, &der)
    guard length > 0, let der else { return nil }
    defer { OPENSSL_free(der) }
    var digest = [UInt8](repeating: 0, count: Int(SHA256_DIGEST_LENGTH))
    SHA256(der, Int(length), &digest)
    return Data(digest)
}
