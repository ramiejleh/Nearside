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
