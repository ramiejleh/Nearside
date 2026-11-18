import Foundation
import Network

/// Finds the phone's `_nearside._tcp` service and keeps one TCP connection to it.
/// Messages are newline-delimited JSON objects. All callbacks arrive on the main queue.
final class PhoneLink {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onMessage: (([String: Any]) -> Void)?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var endpoints: [NWEndpoint] = []
    private var buffer = Data()
    private(set) var isConnected = false

    func start() {
        let browser = NWBrowser(for: .bonjour(type: "_nearside._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.endpoints = results.map(\.endpoint)
            self?.connectIfNeeded()
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { log("browse failed: \(error)") }
        }
        browser.start(queue: .main)
        self.browser = browser
        // Retry periodically in case a connection dropped while the service stayed advertised.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.connectIfNeeded() }
    }

    func send(_ message: [String: Any]) {
        guard isConnected, let connection,
              var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { log("send failed: \(error)") }
        })
    }

    private func connectIfNeeded() {
        guard connection == nil, let endpoint = endpoints.first else { return }
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
        }
        let connection = NWConnection(to: endpoint, using: params)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                isConnected = true
                log("connected to phone (\(endpoint))")
                receive()
                onConnect?()
            case .failed(let error):
                log("connection failed: \(error)")
                reset()
            case .cancelled:
                reset()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { buffer.append(data); drainLines() }
            if done || error != nil {
                log("phone disconnected")
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
