import AppKit
import Foundation

func log(_ message: String) {
    let time = Date().formatted(date: .omitted, time: .standard)
    print("[\(time)] \(message)")
    fflush(stdout)
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

let usage = """
nearside-poc: Nearside proof of concept (clipboard sync over LAN + wireless ADB helper)

USAGE:
  nearside-poc setup <pair-ip:port> <pair-code> [--apk <path>]
      One-time: pair with the phone's Wireless debugging, install the app, grant its
      permissions, and start the clipboard helper.
      On the phone: Developer options → Wireless debugging → "Pair device with pairing code".
  nearside-poc ensure-helper
      Connect over wireless ADB and start the helper if it is not running.
  nearside-poc run
      Sync clipboards both ways and restart the helper automatically when needed.
"""

// Default APK: the Android PoC's debug build, located relative to this source file.
let defaultApk = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("android/app/build/outputs/apk/debug/app-debug.apk").path

@discardableResult
func step(_ title: String, _ result: Adb.Result) -> Bool {
    log("\(result.ok ? "✓" : "✗") \(title)\(result.out.isEmpty ? "" : ": \(result.out)")")
    return result.ok
}

func ensureHelper() -> Bool {
    guard let serial = Adb.ensureConnected() else {
        log("✗ phone not found over wireless debugging (is it on, and on the same Wi-Fi?)")
        return false
    }
    if Adb.helperRunning(serial) {
        log("✓ helper already running on \(serial)")
        return true
    }
    step("start helper on \(serial)", Adb.startHelper(serial))
    Thread.sleep(forTimeInterval: 1.5)
    let running = Adb.helperRunning(serial)
    log(running ? "✓ helper running" : "✗ helper did not start; see: adb shell cat /data/local/tmp/nearside-helper.log")
    return running
}

func setup(pair: String, code: String, apk: String) -> Int32 {
    guard step("pair with \(pair)", Adb.pair(pair, code: code)) else { return 1 }
    guard let serial = Adb.ensureConnected(wait: 20) else {
        log("✗ paired, but could not find the phone's connect port over mDNS")
        return 1
    }
    log("✓ connected: \(serial)")
    guard FileManager.default.fileExists(atPath: apk) else {
        log("✗ APK not found at \(apk) (build it with ./gradlew assembleDebug)")
        return 1
    }
    guard step("install app", Adb.run(["-s", serial, "install", "-r", apk], timeout: 120)) else { return 1 }
    let pkg = Adb.appPackage
    step("grant setup permission", Adb.shell(serial, "pm grant \(pkg) android.permission.WRITE_SECURE_SETTINGS"))
    step("grant notifications", Adb.shell(serial, "pm grant \(pkg) android.permission.POST_NOTIFICATIONS"))
    step("battery optimisation off", Adb.shell(serial, "cmd deviceidle whitelist +\(pkg)"))
    step("never expire this Mac's authorization", Adb.shell(serial, "settings put global adb_allowed_connection_time 0"))
    // Launching once takes the app out of the "stopped" state so it receives BOOT_COMPLETED.
    step("open app", Adb.shell(serial, "am start -n \(pkg)/.MainActivity"))
    return ensureHelper() ? 0 : 1
}

func run() -> Never {
    _ = NSApplication.shared // Pasteboard access from a CLI needs an app instance.
    let link = PhoneLink()
    let board = PasteboardWatcher { text in
        guard link.isConnected else { return }
        log("Mac → phone (\(text.count) chars)")
        link.send(["t": "clip", "text": text, "ts": nowMs()])
    }

    var helperUp = false
    var ensuring = false
    func ensureHelperInBackground() {
        guard !ensuring else { return }
        ensuring = true
        DispatchQueue.global().async {
            _ = ensureHelper()
            DispatchQueue.main.async { ensuring = false }
        }
    }

    link.onMessage = { message in
        switch message["t"] as? String {
        case "clip":
            guard let text = message["text"] as? String else { return }
            let sent = (message["ts"] as? NSNumber)?.int64Value ?? nowMs()
            log("phone → Mac (\(text.count) chars, ~\(nowMs() - sent) ms)")
            board.write(text)
        case "status":
            helperUp = (message["helper"] as? Bool) ?? false
            log("phone status: helper \(helperUp ? "connected" : "not running")")
            if !helperUp { ensureHelperInBackground() }
        default:
            break
        }
    }
    // The phone sends a status message on connect; this timer covers missed updates.
    Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
        if link.isConnected && !helperUp { ensureHelperInBackground() }
    }

    link.start()
    board.start()
    log("running; looking for the phone on the local network…")
    RunLoop.main.run()
    exit(0)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "setup" where args.count >= 3:
    var apk = defaultApk
    if let i = args.firstIndex(of: "--apk"), i + 1 < args.count { apk = args[i + 1] }
    exit(setup(pair: args[1], code: args[2], apk: apk))
case "ensure-helper":
    exit(ensureHelper() ? 0 : 1)
case "run":
    run()
default:
    print(usage)
    exit(args.first == "--help" || args.first == "-h" ? 0 : 1)
}
