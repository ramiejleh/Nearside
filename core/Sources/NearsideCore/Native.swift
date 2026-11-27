#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import NativeAdb

/// The one connection to the pinned phone, made with our own adb client.
///
/// Identity: the phone is found by its hardware serial (in its mDNS name), but it's only
/// trusted by its TLS key, pinned in UserDefaults. adb's protocol never links the pairing to
/// the phone's connection key (the pairing session uses a different key: verified on a Pixel 9
/// Pro, Android 17), so the key is pinned in the setup flow, seconds after the code-checked
/// pairing, only from a device at the IP address the pairing reached, and only if exactly one
/// device there answers as that phone. From then on any other key
/// is refused before adb data flows. Nothing is ever pinned outside the setup flow.
enum Native {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var connection: AdbConnection?
    /// Only keys pinned in the setup flow live here. ("phoneKey" held keys learned on any first
    /// connect by an earlier version; those are ignored, so such setups pair once more.)
    private static let pinKey = "pairedPhoneKey"

    /// Phone-app windows open on this connection: while there are any, the connection checks
    /// the phone often (see `TCPSocket.setKeepalive`).
    nonisolated(unsafe) private static var openWindows = 0

    static var hasOpenWindows: Bool { lock.withLock { openWindows > 0 } }

    static func windowOpened() { changeWindows(by: 1) }
    static func windowClosed() { changeWindows(by: -1) }

    private static func changeWindows(by delta: Int) {
        let (adb, busy) = lock.withLock { () -> (AdbConnection?, Bool) in
            openWindows = max(0, openWindows + delta)
            return (connection, openWindows > 0)
        }
        adb?.setKeepalive(busy: busy)
    }

    /// The live connection, if any.
    static func current() -> AdbConnection? {
        lock.withLock { connection?.isAlive == true ? connection : nil }
    }

    /// After a network change: drops the connection if the Mac's address it was made from is
    /// gone, so the next try reconnects on the new network at once. True if it was dropped.
    static func dropIfNetworkChanged() -> Bool {
        guard let adb = lock.withLock({ connection }), adb.isAlive, adb.localAddressGone else { return false }
        disconnect()
        return true
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
        set { UserDefaults.standard.set(newValue?.hexString, forKey: pinKey); saveSettingsNow() }
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
        let name = Platforms.current.computerName
        return try? key.androidPublicKey(comment: "\(NSUserName())@\(name)")
    }

    /// Reuses the live connection or makes a new one to the pinned phone: over a USB cable when
    /// it's plugged in (and proven to be the paired phone, see `connectUSB`), else Wi-Fi. Never
    /// without a pin: keys are only pinned by `pinAfterPairing`.
    static func connect(pinned serial: String) -> AdbConnection? {
        if let live = current() { return live }
        guard let key = key(), let expected = pinnedKey else { return nil }
        if let usb = connectUSB(pinned: serial, key: key, waitForApproval: 0) { return install(usb) }
        if let wifi = connectWiFi(pinned: serial, key: key, expected: expected) { return wifi }
        // Only on the cable, and the phone hasn't allowed this Mac's key for USB: ask it.
        if let usb = connectUSB(pinned: serial, key: key, waitForApproval: 30) { return install(usb) }
        return nil
    }

    /// Plugged in while connected over Wi-Fi: moves to the cable (open windows resume on it).
    /// Returns true if it moved.
    static func moveToUSB(pinned serial: String) -> Bool {
        guard let live = current(), !live.overUSB, let key = key(),
              let usb = connectUSB(pinned: serial, key: key, waitForApproval: 30) else { return false }
        install(usb)
        return true
    }

    /// Whether the live connection is the cable.
    static var isOverUSB: Bool { current()?.overUSB == true }

    /// The pinned phone's adb interface, if it's plugged in. Ignoring case: Windows may report a
    /// serial in capitals (`connectUSB` checks the phone's exact one).
    static func pluggedIn(_ serial: String) -> USB.Device? {
        let all = USB.devices()
        let match = all.first { $0.serial.caseInsensitiveCompare(serial) == .orderedSame }
        // What the computer sees on its cables, logged as it changes (no serial numbers).
        let seen = all.isEmpty ? "no phone's USB debugging connection on a cable"
            : "\(all.count) USB debugging connection\(all.count == 1 ? "" : "s") on a cable, \(match != nil ? "the paired phone's" : "none the paired phone's")"
        if lock.withLock({ () -> Bool in defer { usbSeen = seen }; return usbSeen != seen }) { usbLog.notice(seen) }
        return match
    }
    nonisolated(unsafe) private static var usbSeen = ""

    /// Plug-ins that didn't work (the phone isn't proven, or another error): not tried again
    /// until plugged in again.
    nonisolated(unsafe) private static var usbFailed: Set<UInt64> = []
    /// A plug-in whose adb interface another program holds (adb's server, Android Studio), and
    /// when that was last seen: tried again every 10 s, so the cable is used once it's let go.
    nonisolated(unsafe) private static var usbBusy: (id: UInt64, at: Date)?
    /// Handshakes that went wrong on a plug-in (leftovers from the program that had the
    /// connection before, a timeout): tried again a few times before giving up on it.
    nonisolated(unsafe) private static var usbRetries: (id: UInt64, count: Int, at: Date)?
    private static let usbLog = Log("usb")

    /// The pinned phone is plugged in, but another program is using its USB connection.
    static func usbInUse(_ serial: String) -> Bool {
        guard let device = pluggedIn(serial) else { return false }
        return lock.withLock { usbBusy?.id == device.id }
    }

    /// A cable has no TLS key to pin, and a serial is easy to fake, so the phone must prove it's
    /// the one we paired with: it holds this Mac's token in a folder only the shell user can read,
    /// written there over the pinned Wi-Fi connection (`Adb.prepareHelper`). We read it back and
    /// compare here; nothing secret is sent to the device before it passes.
    private static func connectUSB(pinned serial: String, key: AdbKey, waitForApproval: TimeInterval) -> AdbConnection? {
        guard let device = pluggedIn(serial), !lock.withLock({ usbFailed.contains(device.id) }),
              lock.withLock({ usbBusy.map { $0.id != device.id || Date().timeIntervalSince($0.at) >= 10 } ?? true }),
              lock.withLock({ usbRetries.map { $0.id != device.id || Date().timeIntervalSince($0.at) >= 3 } ?? true }),
              let publicKey = publicKey(key) else { return nil }
        let adb: AdbConnection
        do {
            adb = try AdbConnection.connectUSB(device, key: key, publicKey: publicKey, waitForApproval: waitForApproval)
        } catch AdbError.needsApproval {
            return nil // tried again with waitForApproval
        } catch AdbError.usbInUse {
            let first = lock.withLock { () -> Bool in
                defer { usbBusy = (device.id, Date()) }
                return usbBusy?.id != device.id
            }
            if first { usbLog.notice("plugged in, but another program is using the USB connection; staying on Wi-Fi") }
            return nil
        } catch let error as AdbError where error.isTransientOnUSB {
            let tries = lock.withLock { () -> Int in
                let count = usbRetries?.id == device.id ? usbRetries!.count + 1 : 1
                usbRetries = (device.id, count, Date())
                if count >= 4 { usbFailed.insert(device.id) }
                return count
            }
            usbLog.error("USB: \(error)\(tries >= 4 ? "; not tried again until plugged in again" : "; trying again")")
            return nil
        } catch {
            usbLog.error("USB: \(error)")
            lock.withLock { _ = usbFailed.insert(device.id) }
            return nil
        }
        lock.withLock { usbBusy = nil; usbRetries = nil }
        let proof = try? adb.shell("cat /data/local/tmp/nearside-macs/\(Token.id) 2>/dev/null; echo; getprop ro.serialno").output
        guard proof == "\(Token.value)\n\(serial)" else {
            usbLog.error("the plugged-in device didn't prove it's the paired phone; not using it")
            adb.close()
            lock.withLock { _ = usbFailed.insert(device.id) }
            return nil
        }
        usbLog.notice("connected over USB")
        return adb
    }

    @discardableResult
    private static func install(_ adb: AdbConnection) -> AdbConnection {
        let busy = lock.withLock { () -> Bool in
            connection?.close()
            connection = adb
            return openWindows > 0
        }
        adb.setKeepalive(busy: busy)
        return adb
    }

    private static func connectWiFi(pinned serial: String, key: AdbKey, expected: Data) -> AdbConnection? {
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
            return install(adb)
        }
        return nil
    }

    enum PinResult { case pinned, conflict, notFound }

    /// Setup only, right after the code-checked pairing: watches the network for up to `wait`
    /// seconds for devices claiming to be this phone *at the address the pairing reached*. Once
    /// one answers it keeps watching for `confirmPasses` more browse rounds, and pins only if
    /// every answer over the whole window had the same key.
    static func pinAfterPairing(serial: String, at pairedHost: String, wait: TimeInterval,
                                confirmPasses: Int = 2) -> PinResult {
        guard let key = key() else { return .notFound }
        disconnect() // never let an earlier live connection stand in for this check
        let deadline = Date().addingTimeInterval(wait)
        var answers: [Data: AdbConnection] = [:] // one connection kept per distinct key
        var passesSinceFirst = 0
        defer { answers.values.forEach { $0.close() } } // whatever isn't handed over below

        while Date() < deadline || (!answers.isEmpty && passesSinceFirst <= confirmPasses) {
            for service in Discovery.browse(Discovery.connectType) where service.name.hasPrefix("adb-\(serial)-") {
                guard let host = ipv4(service.host), host == pairedHost,
                      let adb = try? AdbConnection.connect(host: host, port: service.port, key: key, expectedPeerKey: nil) else { continue }
                guard (try? adb.shell("getprop ro.serialno").output) == serial, answers[adb.peerKeySHA256] == nil else {
                    adb.close()
                    continue
                }
                answers[adb.peerKeySHA256] = adb
            }
            if answers.count > 1 {
                NSLog("Nearside: \(answers.count) devices claim to be the phone with different keys; not pinning any")
                return .conflict
            }
            if !answers.isEmpty {
                passesSinceFirst += 1
                if passesSinceFirst > confirmPasses { break }
            } else {
                Thread.sleep(forTimeInterval: 1)
            }
        }
        guard let (peerKey, chosen) = answers.first, chosen.isAlive else { return .notFound }
        answers = [:] // handed over, not closed
        pinnedKey = peerKey
        lock.withLock {
            connection?.close()
            connection = chosen
        }
        return .pinned
    }

    /// "ip:port" for a discovered service (what `adb pair` wants).
    static func address(_ service: Discovery.Service) -> String? {
        ipv4(service.host).map { "\($0):\(service.port)" }
    }

    /// Resolves an mDNS host name ("Android_X.local.") to an IPv4 address.
    static func ipv4(_ host: String) -> String? {
        var hints = addrinfo() // fields set by name: their order differs between systems
        hints.ai_family = AF_INET
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr in
            var a = addr.pointee.sin_addr
            #if os(Windows)
            let size = buffer.count // size_t there
            #else
            let size = socklen_t(buffer.count)
            #endif
            return inet_ntop(AF_INET, &a, &buffer, size).map { String(cString: $0) }
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
