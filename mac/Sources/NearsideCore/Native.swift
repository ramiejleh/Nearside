import Darwin
import Foundation
import NativeAdb

/// The one connection to the pinned phone, made with our own adb client.
///
/// Identity: the phone is found by its hardware serial (in its mDNS name, checked with
/// `getprop`), but it's only trusted by its TLS key, pinned in UserDefaults "phoneKey". The key
/// is learned only when the caller says so (the user-run pairing flow, or once for a setup made
/// before pinning existed); after that a different key is refused before any adb data flows.
/// A look-alike device on the network can copy the serial, but not the phone's key.
enum Native {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var connection: AdbConnection?
    private static let pinKey = "phoneKey"

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

    /// Our adb identity: stock adb's key, so phones paired with `adb pair` accept us.
    static func key() -> AdbKey? {
        try? AdbKey(pemFile: AdbKey.defaultPath)
    }

    /// Reuses the live connection or makes a new one to the pinned phone.
    static func connect(pinned serial: String, learnKey: Bool) -> AdbConnection? {
        if let live = current() { return live }
        guard let key = key() else { return nil }
        let expected = pinnedKey
        guard expected != nil || learnKey else { return nil } // never trust an unpinned phone silently

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
            // The serial in the mDNS name is just a claim: check it on the device itself.
            guard (try? adb.shell("getprop ro.serialno").output) == serial else {
                adb.close()
                continue
            }
            if expected == nil { pinnedKey = adb.peerKeySHA256 }
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
