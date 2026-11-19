import Foundation

/// Thin, blocking wrapper over the `adb` binary. Call it off the main thread.
public enum Adb {
    static let appPackage = "dev.nearside"
    static let helperPort: UInt16 = 47801

    /// nil when adb isn't installed (the app then shows install instructions).
    public static let path: String? = {
        var candidates: [String] = []
        if let home = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
            candidates.append("\(home)/platform-tools/adb")
        }
        candidates += [
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    public struct Result: Sendable {
        public let code: Int32
        public let out: String
        public var ok: Bool { code == 0 }
    }

    @discardableResult
    static func run(_ args: [String], timeout: TimeInterval = 30) -> Result {
        guard let path else { return Result(code: -1, out: "adb not found") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(code: -1, out: "cannot run adb: \(error.localizedDescription)")
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(code: process.terminationStatus, out: out)
    }

    static func shell(_ serial: String, _ command: String, timeout: TimeInterval = 30) -> Result {
        run(["-s", serial, "shell", command], timeout: timeout)
    }

    /// `ip:port` endpoints of phones advertising wireless debugging (`_adb-tls-connect._tcp`).
    static func wirelessEndpoints() -> [String] {
        run(["mdns", "services"]).out
            .split(separator: "\n")
            .filter { $0.contains("_adb-tls-connect._tcp") }
            .compactMap { line in line.split(whereSeparator: { $0 == "\t" || $0 == " " }).last.map(String.init) }
            .filter { $0.contains(":") }
    }

    /// A serial already attached over the network, if any.
    static func connectedWirelessSerial() -> String? {
        run(["devices"]).out
            .split(separator: "\n")
            .compactMap { line -> String? in
                let parts = line.split(separator: "\t")
                guard parts.count == 2, parts[1] == "device" else { return nil }
                let serial = String(parts[0])
                return serial.contains(":") || serial.contains("_adb-tls-connect") ? serial : nil
            }
            .first
    }

    /// Finds the phone over mDNS and connects. Polls for up to `wait` seconds.
    static func ensureConnected(wait: TimeInterval = 0) -> String? {
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            if let serial = connectedWirelessSerial() { return serial }
            for endpoint in wirelessEndpoints() {
                let r = run(["connect", endpoint], timeout: 10)
                if r.out.contains("connected to") { return connectedWirelessSerial() ?? endpoint }
            }
            if wait > 0 { Thread.sleep(forTimeInterval: 1) }
        } while Date() < deadline
        return nil
    }

    static func model(_ serial: String) -> String? {
        let out = shell(serial, "getprop ro.product.model").out
        return out.isEmpty ? nil : out
    }

    static func helperRunning(_ serial: String) -> Bool {
        shell(serial, "ps -A -o NAME").out.contains("nearside-helper")
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

    /// Tunnels localhost:`helperPort` to the helper's abstract socket over adb's TLS connection.
    static func forward(_ serial: String) -> Result {
        run(["-s", serial, "forward", "tcp:\(helperPort)", "localabstract:nearside-helper"])
    }

    public struct Phone: Sendable, Equatable {
        public let serial: String
        public let model: String?
    }

    /// Connects, starts the helper if needed, and (re)creates the tunnel. nil when unreachable.
    static func prepareHelper() -> Phone? {
        guard let serial = ensureConnected() else { return nil }
        if !helperRunning(serial) {
            _ = startHelper(serial)
            Thread.sleep(forTimeInterval: 1.5)
            guard helperRunning(serial) else { return nil }
        }
        guard forward(serial).ok else { return nil }
        return Phone(serial: serial, model: model(serial))
    }

    /// Android revokes an ADB host after 7 days without a fresh connection; reconnecting renews it.
    static func renewAuthorization() {
        if let serial = connectedWirelessSerial() { run(["disconnect", serial]) }
        _ = ensureConnected()
    }
}
