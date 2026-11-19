import AppKit
import Foundation

func log(_ message: String) {
    let time = Date().formatted(date: .omitted, time: .standard)
    print("[\(time)] \(message)")
    fflush(stdout)
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

let usage = """
nearside-poc: Nearside proof of concept (clipboard sync through a wireless-ADB helper)

USAGE:
  nearside-poc setup <pair-ip:port> <pair-code> [--apk <path>]
      One-time: pair with the phone's Wireless debugging, install the app, grant its
      permissions, and start the clipboard helper.
      On the phone: Developer options → Wireless debugging → "Pair device with pairing code".
  nearside-poc ensure-helper
      Connect over wireless ADB, start the helper if needed, and open the tunnel to it.
  nearside-poc run
      Sync clipboards both ways, re-establishing the helper and tunnel automatically.
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

/// Connects over wireless ADB, starts the helper if needed, and (re)creates the tunnel.
func ensureHelper(quiet: Bool = false) -> Bool {
    guard let serial = Adb.ensureConnected() else {
        if !quiet { log("✗ phone not found over wireless debugging (is it on, and on the same Wi-Fi?)") }
        return false
    }
    if !Adb.helperRunning(serial) {
        step("start helper on \(serial)", Adb.startHelper(serial))
        Thread.sleep(forTimeInterval: 1.5)
        guard Adb.helperRunning(serial) else {
            log("✗ helper did not start; see: adb shell cat /data/local/tmp/nearside-helper.log")
            return false
        }
        log("✓ helper running")
    }
    return quiet ? Adb.forward(serial, port: HelperLink.localPort).ok
                 : step("tunnel localhost:\(HelperLink.localPort) → helper", Adb.forward(serial, port: HelperLink.localPort))
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
    // Launching once takes the app out of the "stopped" state so it receives BOOT_COMPLETED.
    step("open app", Adb.shell(serial, "am start -n \(pkg)/.MainActivity"))
    return ensureHelper() ? 0 : 1
}

func run() -> Never {
    _ = NSApplication.shared // Pasteboard access from a CLI needs an app instance.
    let link = HelperLink()
    var ready = false // the helper accepted our token and said hello

    let board = PasteboardWatcher { text in
        guard ready else { return }
        log("Mac → phone (\(text.count) chars)")
        link.send(["t": "clip", "text": text, "ts": nowMs()])
    }

    link.onMessage = { message in
        switch message["t"] as? String {
        case "hello":
            ready = true
            log("✓ helper connected (Android SDK \(message["sdk"] ?? "?"))")
        case "clip":
            guard ready, let text = message["text"] as? String else { return }
            let sent = (message["ts"] as? NSNumber)?.int64Value ?? nowMs()
            log("phone → Mac (\(text.count) chars, ~\(nowMs() - sent) ms)")
            board.write(text)
        default:
            break
        }
    }
    link.onDisconnect = {
        if ready { log("helper link lost; will retry") }
        ready = false
    }

    // Keep the tunnel and helper alive. When idle, (re)establish them off the main queue,
    // then connect. Quiet retries every 3 s, with a visible status line once a minute.
    var ensuring = false
    var lastComplaint = Date.distantPast
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
        guard link.isIdle, !ensuring else { return }
        ensuring = true
        let loud = Date().timeIntervalSince(lastComplaint) > 60
        if loud { lastComplaint = Date() }
        DispatchQueue.global().async {
            let ok = ensureHelper(quiet: !loud)
            DispatchQueue.main.async {
                ensuring = false
                if ok { link.connect() }
            }
        }
    }.fire()

    // Android revokes an ADB host after 7 days without a connection. Reconnecting every 6 h
    // keeps this Mac authorised without disabling that expiry.
    Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
        DispatchQueue.global().async {
            if let serial = Adb.connectedWirelessSerial() { Adb.run(["disconnect", serial]) }
            _ = ensureHelper(quiet: true)
        }
    }

    board.start()
    log("running")
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
