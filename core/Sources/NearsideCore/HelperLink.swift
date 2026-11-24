#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import NativeAdb

/// The link to the helper: an adb stream straight to its abstract socket, over the pinned
/// phone connection (no port forwarding, so nothing listens on this Mac). Messages are
/// newline-delimited JSON objects.
@MainActor
final class HelperLink {
    var onMessage: (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?

    private var stream: AdbStream?
    private var connecting = false
    private let writer = DispatchQueue(label: "dev.nearside.helper-writer")
    private var buffer = Data()
    private(set) var isConnected = false
    private var verified = false
    private var ourNonce = ""
    var isIdle: Bool { stream == nil && !connecting }
    /// Only take the phone if no other Mac is using it (after being taken over; see the helper).
    var passive = false

    func connect() {
        guard isIdle else { return }
        connecting = true
        Task {
            let stream = await Task.detached { try? Adb.openHelperStream() }.value
            connecting = false
            guard let stream else { return } // the next tick retries
            attach(stream)
        }
    }

    private func attach(_ stream: AdbStream) {
        self.stream = stream
        isConnected = true
        verified = false
        buffer.removeAll()
        scanned = 0
        // Mutual challenge-response (see helper/Main.kt `serve`). Nothing else is sent or
        // delivered until the helper has proven it knows the token.
        ourNonce = Self.randomHex()
        var hello: [String: Any] = ["t": "hello-mac", "nonce": ourNonce, "id": Token.id, "name": Platforms.current.computerName, "passive": passive]
        if let os = Platforms.current.osName { hello["os"] = os } // a PC says so; the phone words its text by it
        sendRaw(hello)

        // Weak, and only touched on the main queue (older compilers reject capturing self here).
        nonisolated(unsafe) weak var link = self
        let reader = Thread {
            while let data = try? stream.read() {
                DispatchQueue.main.async { link?.received(data, on: stream) }
            }
            DispatchQueue.main.async { link?.closed(stream) }
        }
        reader.name = "helper-reader"
        reader.start()

        // A peer that never completes the handshake must not hold the link forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.stream === stream, !self.verified else { return }
            stream.close()
        }
    }

    func disconnect() {
        stream?.close()
    }

    /// Sends app messages; dropped until the helper is verified.
    func send(_ message: [String: Any]) {
        guard verified else { return }
        sendRaw(message)
    }

    private func sendRaw(_ message: [String: Any]) {
        guard isConnected, let stream,
              var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        writer.async {
            if (try? stream.write(data)) == nil { stream.close() }
        }
    }

    private func received(_ data: Data, on stream: AdbStream) {
        guard self.stream === stream else { return }
        buffer.append(data)
        drainLines()
    }

    private func closed(_ stream: AdbStream) {
        guard self.stream === stream else { return }
        reset()
    }

    private func handshake(_ message: [String: Any]) {
        let key = SymmetricKey(data: Data(Token.value.utf8))
        guard message["t"] as? String == "challenge",
              let proof = (message["proof"] as? String).flatMap(Self.hexBytes),
              let theirNonce = message["nonce"] as? String, theirNonce.count == 64,
              HMAC<SHA256>.isValidAuthenticationCode(
                  proof, authenticating: Data("nearside-helper:\(ourNonce)".utf8), using: key) else {
            // Not our helper (e.g. an app squatting the socket name): say nothing, hang up.
            stream?.close()
            return
        }
        let ours = HMAC<SHA256>.authenticationCode(for: Data("nearside-mac:\(theirNonce)".utf8), using: key)
        sendRaw(["t": "auth", "proof": ours.map { String(format: "%02x", $0) }.joined()])
        verified = true
    }

    private static func randomHex() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexBytes(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// Where the newline search resumes: long lines (icons) arrive in many chunks, and searching
    /// from the start each time was quadratic.
    private var scanned = 0

    private func drainLines() {
        while let newline = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            scanned = 0
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if verified { onMessage?(object) } else { handshake(object) }
        }
        scanned = buffer.count
    }

    private func reset() {
        let wasConnected = isConnected
        isConnected = false
        verified = false
        stream = nil
        buffer.removeAll()
        scanned = 0
        if wasConnected { onDisconnect?() }
    }
}
