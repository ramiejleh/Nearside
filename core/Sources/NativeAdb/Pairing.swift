import CNIOBoringSSL
import Foundation

/// Wireless-debugging pairing ("Pair device with QR code / pairing code"), as AOSP adb's
/// pairing_auth + pairing_connection: TLS 1.3, then SPAKE2 (ed25519) with the code plus a TLS
/// exporter value as the password, then each side's PeerInfo sealed with AES-128-GCM. The
/// phone learns our public key; we learn its GUID ("adb-<serial>-<random>"). Because the TLS
/// session is bound into SPAKE2, the phone's TLS key seen here is authenticated by the code:
/// it's the key to pin.
public enum Pairing {
    public struct Result: Sendable {
        public let guid: String        // e.g. "adb-ABC123XYZ0001-AbCdEf"
        public let peerKeySHA256: Data // the phone's TLS key, authenticated by the code

        public init(guid: String, peerKeySHA256: Data) {
            self.guid = guid
            self.peerKeySHA256 = peerKeySHA256
        }

        /// The hardware serial inside the GUID.
        public var serial: String? {
            let parts = guid.split(separator: "-")
            return parts.count >= 3 && parts[0] == "adb" ? String(parts[1]) : nil
        }
    }

    public enum Failure: Error, CustomStringConvertible, Sendable {
        case wrongCode
        case failed(String)
        public var description: String {
            switch self {
            case .wrongCode: "The pairing code didn't match."
            case .failed(let m): m
            }
        }
    }

    private static let clientName = Array("adb pair client".utf8) + [0] // sizeof() includes NUL
    private static let serverName = Array("adb pair server".utf8) + [0]
    private static let exporterLabel = Array("adb-label".utf8) + [0]
    private static let peerInfoSize = 8192
    private static let spake2Message: UInt8 = 0, peerInfo: UInt8 = 1

    public static func pair(host: String, port: UInt16, code: String, key: AdbKey, publicKey: String,
                            timeout: TimeInterval = 15) throws -> Result {
        let socket = try TCPSocket(host: host, port: port, timeout: timeout)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(socket.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // Both sides speak right after the handshake, so no post-handshake peek here.
        let tls = try TLSChannel(socket: socket, key: key, expectedPeerKey: nil, peekAfterHandshake: false)
        defer { tls.close() }
        guard let exported = tls.exportKeyingMaterial(label: exporterLabel, length: 64) else {
            throw Failure.failed("TLS exporter failed")
        }
        let password = Array(code.utf8) + Array(exported)

        // SPAKE2: we're Alice ("client").
        guard let spake = SPAKE2_CTX_new(spake2_role_alice, clientName, clientName.count, serverName, serverName.count) else {
            throw Failure.failed("SPAKE2 init")
        }
        defer { SPAKE2_CTX_free(spake) }
        var ours = [UInt8](repeating: 0, count: 32) // SPAKE2_MAX_MSG_SIZE
        var oursLength = 0
        guard SPAKE2_generate_msg(spake, &ours, &oursLength, ours.count, password, password.count) == 1 else {
            throw Failure.failed("SPAKE2 message")
        }
        try write(tls, type: spake2Message, Data(ours[0..<oursLength]))
        let theirs = try read(tls, expecting: spake2Message)
        var material = [UInt8](repeating: 0, count: 64) // SPAKE2_MAX_KEY_SIZE
        var materialLength = 0
        guard SPAKE2_process_msg(spake, &material, &materialLength, material.count, Array(theirs), theirs.count) == 1 else {
            throw Failure.wrongCode
        }

        // AES-128-GCM, key = HKDF-SHA256(material, info "adb pairing_auth aes-128-gcm key").
        var aesKey = [UInt8](repeating: 0, count: 16)
        let info = Array("adb pairing_auth aes-128-gcm key".utf8)
        guard HKDF(&aesKey, 16, EVP_sha256(), material, materialLength, nil, 0, info, info.count) == 1 else {
            throw Failure.failed("HKDF")
        }
        var aead = EVP_AEAD_CTX()
        guard EVP_AEAD_CTX_init(&aead, EVP_aead_aes_128_gcm(), aesKey, 16, Int(EVP_AEAD_DEFAULT_TAG_LENGTH), nil) == 1 else {
            throw Failure.failed("AES init")
        }
        defer { EVP_AEAD_CTX_cleanup(&aead) }

        // Our PeerInfo: type 0 (RSA public key) + the key string, NUL-padded to 8192 bytes.
        var info8k = [UInt8](repeating: 0, count: peerInfoSize)
        let keyBytes = Array(publicKey.utf8)
        guard keyBytes.count < peerInfoSize - 1 else { throw Failure.failed("public key too long") }
        info8k.replaceSubrange(1..<(1 + keyBytes.count), with: keyBytes)
        var sealed = [UInt8](repeating: 0, count: peerInfoSize + Int(EVP_AEAD_max_overhead(EVP_aead_aes_128_gcm())))
        var sealedLength = 0
        let nonce = [UInt8](repeating: 0, count: 12) // sequence 0 (u64 LE) in a zeroed nonce
        guard EVP_AEAD_CTX_seal(&aead, &sealed, &sealedLength, sealed.count, nonce, nonce.count,
                                info8k, info8k.count, nil, 0) == 1 else { throw Failure.failed("encrypt") }
        try write(tls, type: peerInfo, Data(sealed[0..<sealedLength]))

        // Theirs. A wrong code shows up here: we can't open what they sealed (or they hang up).
        let reply: Data
        do {
            reply = try read(tls, expecting: peerInfo)
        } catch {
            throw Failure.wrongCode
        }
        var opened = [UInt8](repeating: 0, count: reply.count)
        var openedLength = 0
        guard EVP_AEAD_CTX_open(&aead, &opened, &openedLength, opened.count, nonce, nonce.count,
                                Array(reply), reply.count, nil, 0) == 1 else { throw Failure.wrongCode }
        guard openedLength == peerInfoSize, opened[0] == 1 else { throw Failure.failed("unexpected reply from the phone") }
        let guidBytes = opened[1...].prefix { $0 != 0 }
        return Result(guid: String(decoding: guidBytes, as: UTF8.self), peerKeySHA256: tls.peerKeySHA256)
    }

    /// Pairing packets: u8 version (1), u8 type, u32 payload length (big-endian), payload.
    private static func write(_ tls: TLSChannel, type: UInt8, _ payload: Data) throws {
        var data = Data([1, type])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        try tls.write(data)
    }

    private static func read(_ tls: TLSChannel, expecting type: UInt8) throws -> Data {
        let header = try tls.readExactly(6)
        let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 2, as: UInt32.self))) }
        guard header[header.startIndex] == 1, header[header.startIndex + 1] == type,
              length > 0, length <= peerInfoSize * 2 else { throw Failure.failed("bad pairing packet") }
        return try tls.readExactly(length)
    }
}
