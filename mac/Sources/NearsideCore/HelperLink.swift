import CryptoKit
import Foundation
import Network

/// One TCP connection to the helper through `adb forward` (localhost → adb TLS → phone).
/// Messages are newline-delimited JSON objects.
@MainActor
final class HelperLink {
    var onMessage: (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?

    private var connection: NWConnection?
    private var buffer = Data()
    private(set) var isConnected = false
    private var verified = false
    private var ourNonce = ""
    var isIdle: Bool { connection == nil }

    func connect() {
        guard connection == nil else { return }
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Adb.helperPort)!, using: params)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    // Mutual challenge-response (see helper/Main.kt `serve`). Nothing else is sent
                    // or delivered until the helper has proven it knows the token.
                    self.isConnected = true
                    self.verified = false
                    self.ourNonce = Self.randomHex()
                    self.sendRaw(["t": "hello-mac", "nonce": self.ourNonce])
                    self.receive()
                    // A peer that never completes the handshake must not hold the link forever.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.connection === connection, !self.verified else { return }
                            connection.cancel()
                        }
                    }
                case .failed, .cancelled:
                    self.reset()
                case .waiting:
                    self.connection?.cancel()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    func disconnect() {
        connection?.cancel()
    }

    /// Sends app messages; dropped until the helper is verified.
    func send(_ message: [String: Any]) {
        guard verified else { return }
        sendRaw(message)
    }

    private func sendRaw(_ message: [String: Any]) {
        guard isConnected, let connection,
              var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func handshake(_ message: [String: Any]) {
        let key = SymmetricKey(data: Data(Token.value.utf8))
        guard message["t"] as? String == "challenge",
              let proof = (message["proof"] as? String).flatMap(Self.hexBytes),
              let theirNonce = message["nonce"] as? String, theirNonce.count == 64,
              HMAC<SHA256>.isValidAuthenticationCode(
                  proof, authenticating: Data("nearside-helper:\(ourNonce)".utf8), using: key) else {
            // Not our helper (e.g. an app squatting the socket name): say nothing, hang up.
            connection?.cancel()
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

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data {
                    self.buffer.append(data)
                    self.drainLines()
                }
                if done || error != nil {
                    self.connection?.cancel()
                    return
                }
                self.receive()
            }
        }
    }

    private func drainLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if verified { onMessage?(object) } else { handshake(object) }
        }
    }

    private func reset() {
        let wasConnected = isConnected
        isConnected = false
        verified = false
        connection = nil
        buffer.removeAll()
        if wasConnected { onDisconnect?() }
    }
}
