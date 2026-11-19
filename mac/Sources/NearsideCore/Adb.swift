import Foundation
import NativeAdb

/// Talking to the phone, entirely through our own adb client (NativeAdb) over one pinned
/// connection: pairing, shell, file transfer, install, the helper stream. No adb binary.
/// Blocking: call it off the main thread. The `serial` parameters are kept for the callers'
/// sake but there is only ever one phone, the pinned one.
public enum Adb {
    static let appPackage = "dev.nearside"

    public struct Result: Sendable {
        public let code: Int32
        public let out: String
        public var ok: Bool { code == 0 }
    }

    static func shell(_ serial: String, _ command: String, timeout: TimeInterval = 30) -> Result {
        guard let adb = Native.current() else { return Result(code: -1, out: "not connected") }
        do {
            let r = try adb.shell(command, timeout: timeout)
            return Result(code: r.exitCode, out: r.output)
        } catch {
            return Result(code: -1, out: "\(error)")
        }
    }

    /// The pairing service a phone advertises after scanning our QR code: "ip:port" for `adb pair`.
    static func pairingEndpoint(named name: String) -> String? {
        Discovery.browse(Discovery.pairingType, timeout: 1).first { $0.name == name }.flatMap(Native.address)
    }

    /// The phone's hardware serial, used to pin the one phone we paired with.
    static func hardwareSerial(_ serial: String) -> String? {
        let out = shell(serial, "getprop ro.serialno").out
        return out.isEmpty ? nil : out
    }

    /// Pairs with the phone's "Pair device" screen. On success: its serial (from the GUID in
    /// the code-authenticated reply) and the IPv4 address the pairing reached.
    static func pair(hostPort: String, code: String) -> Swift.Result<(serial: String, host: String), PairError> {
        let parts = hostPort.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            return .failure(PairError(message: "Couldn't reach the phone. Check the IP address and port."))
        }
        guard let key = Native.key(), let publicKey = Native.publicKey(key) else {
            return .failure(PairError(message: "Couldn't create this Mac's key."))
        }
        do {
            guard let host = Native.ipv4(String(parts[0])) else {
                return .failure(PairError(message: "Couldn't reach the phone. Check the IP address and port."))
            }
            let result = try Pairing.pair(host: host, port: port, code: code, key: key, publicKey: publicKey)
            guard let serial = result.serial else { return .failure(PairError(message: "The phone sent an unexpected reply.")) }
            return .success((serial, host))
        } catch Pairing.Failure.wrongCode {
            return .failure(PairError(message: "The pairing code didn't work. Codes expire quickly; tap \"Pair device with pairing code\" again for a new one."))
        } catch AdbError.connect {
            return .failure(PairError(message: "Couldn't reach the phone. Check the IP address and port, and that both devices are on the same Wi-Fi."))
        } catch {
            return .failure(PairError(message: "Pairing didn't work (\(error)). Try again."))
        }
    }

    public struct PairError: Error, Sendable { public let message: String }

    /// Connects (or reuses the connection) to the pinned phone. Returns its hardware serial,
    /// which callers pass back in as `serial`. Polls for up to `wait` seconds.
    static func ensureConnected(pinned: String, wait: TimeInterval = 0, pinningAt pairedHost: String? = nil) -> String? {
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            if Native.connect(pinned: pinned, pinningAt: pairedHost) != nil { return pinned }
            if Native.lastPinningConflict { return nil }
            if wait > 0 { Thread.sleep(forTimeInterval: 1) }
        } while Date() < deadline
        return nil
    }

    static func model(_ serial: String) -> String? {
        Native.current()?.property("ro.product.model")
    }

    /// True only for a process named exactly `nearside-helper` owned by the shell user:
    /// an app can pick a similar process name, but can never run as shell.
    static func helperRunning(_ serial: String) -> Bool {
        shell(serial, "ps -A -o USER,NAME").out
            .split(separator: "\n")
            .contains { $0.split(whereSeparator: \.isWhitespace) == ["shell", "nearside-helper"] }
    }

    /// Launches the privileged helper in its own session so it outlives this adb connection.
    /// The token travels as an env var: only the shell user can read the helper's environment.
    static func startHelper(_ serial: String) -> Result {
        let command = """
        P=$(pm path \(appPackage) | head -1 | cut -d: -f2); \
        NEARSIDE_TOKEN=\(Token.value) CLASSPATH=$P setsid app_process / dev.nearside.helper.Main \
        </dev/null >/data/local/tmp/nearside-helper.log 2>&1 &
        """
        return shell(serial, command, timeout: 15)
    }

    public struct Phone: Sendable, Equatable {
        public let serial: String
        public let hardwareSerial: String?
        public let model: String?
    }

    /// Connects and starts the helper if needed. nil when unreachable. (The Mac then opens a
    /// stream straight to the helper's socket over this connection: no port forwarding.)
    static func prepareHelper(pinned: String) -> Phone? {
        guard let serial = ensureConnected(pinned: pinned) else { return nil }
        if !helperRunning(serial) {
            _ = startHelper(serial)
            Thread.sleep(forTimeInterval: 1.5)
            guard helperRunning(serial) else { return nil }
        }
        return Phone(serial: serial, hardwareSerial: serial, model: model(serial))
    }

    /// A stream to the helper's abstract socket, over the pinned connection.
    static func openHelperStream() throws -> AdbStream {
        guard let adb = Native.current() else { throw AdbError.closed }
        return try adb.open("localabstract:nearside-helper")
    }

    /// Installs (or updates) the phone app.
    static func install(_ apk: URL) -> Result {
        guard let adb = Native.current() else { return Result(code: -1, out: "not connected") }
        do {
            return Result(code: 0, out: try adb.install(apk))
        } catch {
            return Result(code: -1, out: "\(error)")
        }
    }

    /// Grants or revokes the app's notification access (no settings screen needed).
    @discardableResult
    static func setNotificationAccess(_ serial: String, allowed: Bool) -> Bool {
        let component = "\(appPackage)/\(appPackage).NotificationMirror"
        return shell(serial, "cmd notification \(allowed ? "allow_listener" : "disallow_listener") \(component)").ok
    }

    /// Lets the phone app post "Received from your Mac" notifications.
    static func grantPostNotifications(_ serial: String) {
        _ = shell(serial, "pm grant \(appPackage) android.permission.POST_NOTIFICATIONS")
    }

    /// Grants or revokes reading/sending SMS and reading contacts (for names in Messages).
    static func setSmsAccess(_ serial: String, allowed: Bool) {
        let verb = allowed ? "grant" : "revoke"
        var commands = ["READ_SMS", "SEND_SMS", "READ_CONTACTS"].map { "pm \(verb) \(appPackage) android.permission.\($0)" }
        // Without this app-op Android silently ignores our writes (marking texts read).
        commands.append("appops set \(appPackage) WRITE_SMS \(allowed ? "allow" : "default")")
        _ = shell(serial, commands.joined(separator: "; "))
    }

    /// Android's "<app> pasted from your clipboard" toast is a phone-wide setting
    /// (Settings → Privacy → Show clipboard access). nil when unknown.
    static func clipboardToastHidden(_ serial: String) -> Bool? {
        let r = shell(serial, "settings get secure clipboard_show_access_notifications")
        guard r.ok else { return nil }
        return r.out == "0" // "null" (never changed) and "1" both mean shown
    }

    static func setClipboardToastHidden(_ serial: String, _ hidden: Bool) -> Bool {
        shell(serial, "settings put secure clipboard_show_access_notifications \(hidden ? 0 : 1)").ok
    }

    static let phoneInbox = "/sdcard/Download/Nearside"

    /// Single-quotes a string for the phone's shell.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Pushes a file into Download/Nearside, renaming "x.pdf" to "x (2).pdf" if it exists.
    /// Returns the name it got on the phone, or an error message.
    static func push(_ serial: String, file: URL) -> Swift.Result<String, PushError> {
        _ = shell(serial, "mkdir -p \(shellQuote(phoneInbox))")
        let name = FileNames.safe(file.lastPathComponent)
        var candidate = name
        var n = 2
        while shell(serial, "test -e \(shellQuote("\(phoneInbox)/\(candidate)"))").ok, n < 1000 {
            candidate = FileNames.numbered(name, n)
            n += 1
        }
        let remote = "\(phoneInbox)/\(candidate)"
        guard let adb = Native.current() else { return .failure(PushError(message: "not connected")) }
        do {
            // Dated now (not the Mac's modification date) so it shows at the top of Downloads.
            try adb.push(file, to: remote, modified: Date())
        } catch {
            return .failure(PushError(message: "\(error)"))
        }
        let uri = URL(fileURLWithPath: remote).absoluteString
        _ = shell(serial, "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(shellQuote(uri))")
        return .success(candidate)
    }

    public struct PushError: Error, Sendable { public let message: String }

    static func pull(_ serial: String, remote: String, to local: URL) -> Bool {
        guard let adb = Native.current() else { return false }
        return (try? adb.pull(remote, to: local)) != nil
    }

    /// Android revokes an ADB host after 7 days without a fresh connection; reconnecting renews it.
    static func renewAuthorization(pinned: String) {
        Native.disconnect()
        _ = ensureConnected(pinned: pinned)
    }
}
