import Foundation
import Network

/// One TCP connection to the helper through `adb forward` (localhost → adb TLS → phone).
/// Messages are newline-delimited JSON objects. All callbacks arrive on the main queue.
final class HelperLink {
    static let localPort: UInt16 = 47801

    var onMessage: (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?

    private var connection: NWConnection?
    private var buffer = Data()
    private(set) var isConnected = false
    var isIdle: Bool { connection == nil }

    func connect() {
        guard connection == nil else { return }
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.localPort)!, using: params)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                isConnected = true
                // adb's tunnel is TLS, so the raw token never touches the LAN.
                send(["t": "auth", "token": Token.value])
                receive()
            case .failed, .cancelled:
                reset()
            case .waiting:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: [String: Any]) {
        guard isConnected, let connection,
              var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { log("send failed: \(error)") }
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { buffer.append(data); drainLines() }
            if done || error != nil {
                connection?.cancel()
                return
            }
            receive()
        }
    }

    private func drainLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                onMessage?(object)
            }
        }
    }

    private func reset() {
        let wasConnected = isConnected
        isConnected = false
        connection = nil
        buffer.removeAll()
        if wasConnected { onDisconnect?() }
    }
}
