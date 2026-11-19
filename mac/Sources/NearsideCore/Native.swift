import Darwin
import Foundation
import NativeAdb

/// The one connection to the pinned phone, made with our own adb client.
///
/// Identity: the phone is found by its hardware serial (in its mDNS name), but it's only
/// trusted by its TLS key, pinned in UserDefaults "phoneKey". That key comes from the pairing
/// exchange, where SPAKE2 binds it to the code shown on the phone, so a look-alike device on
/// the network can't get pinned and is refused before any adb data flows. Nothing is ever
/// trusted on first connect.
enum Native {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var connection: AdbConnection?
    /// Only keys from the pairing exchange live here. ("phoneKey" held keys learned on first
    /// connect by an earlier version; those are ignored, so such setups pair once more.)
    private static let pinKey = "pairedPhoneKey"

    /// The live connection, if any.
    static func current() -> AdbConnection? {
        lock.withLock { connection?.isAlive == true ? connection : nil }
    }

    static func disconnect() {
        let old = lock.withLock { () -> AdbConnection? in
            defer { connection = nil }
            return connection
        }
        old?.close()
    }

    static var pinnedKey: Data? {
        get { UserDefaults.standard.string(forKey: pinKey).flatMap { Data(hexString: $0) } }
        set { UserDefaults.standard.set(newValue?.hexString, forKey: pinKey) }
    }

    /// Our adb identity: stock adb's key if this Mac has one (phones paired with it accept us),
    /// else our own, made on first use and kept owner-only in Application Support.
    static func key() -> AdbKey? {
        if let stock = try? AdbKey(pemFile: AdbKey.defaultPath) { return stock }
        let own = Paths.support.appendingPathComponent("adbkey")
        if let existing = try? AdbKey(pemFile: own.path) { return existing }
        guard let fresh = try? AdbKey.generate(), let pem = try? fresh.pemData() else { return nil }
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: own.path, contents: pem, attributes: [.posixPermissions: 0o600]) else { return nil }
        return fresh
    }

    /// How this Mac shows up in the phone's "Paired devices" list.
    static func publicKey(_ key: AdbKey) -> String? {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return try? key.androidPublicKey(comment: "\(NSUserName())@\(name)")
    }

    /// Reuses the live connection or makes a new one to the pinned phone. Never without a pin.
    static func connect(pinned serial: String) -> AdbConnection? {
        if let live = current() { return live }
        guard let key = key(), let expected = pinnedKey else { return nil }

        for service in Discovery.browse(Discovery.connectType) where service.name.hasPrefix("adb-\(serial)-") {
            guard let host = ipv4(service.host) else { continue }
            let adb: AdbConnection
            do {
                adb = try AdbConnection.connect(host: host, port: service.port, key: key, expectedPeerKey: expected)
            } catch AdbError.wrongPhone {
                NSLog("Nearside: \(service.name) has a different key than the paired phone; ignoring it")
                continue
            } catch {
                continue
            }
            // The key matched, so this is the paired phone; the serial is a sanity check.
            guard (try? adb.shell("getprop ro.serialno").output) == serial else {
                adb.close()
                continue
            }
            lock.withLock {
                connection?.close()
                connection = adb
            }
            return adb
        }
        return nil
    }

    /// "ip:port" for a discovered service (what `adb pair` wants).
    static func address(_ service: Discovery.Service) -> String? {
        ipv4(service.host).map { "\($0):\(service.port)" }
    }

    /// Resolves an mDNS host name ("Android_X.local.") to an IPv4 address.
    static func ipv4(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr in
            var a = addr.pointee.sin_addr
            return inet_ntop(AF_INET, &a, &buffer, socklen_t(buffer.count)).map { String(cString: $0) }
        }
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
