import Foundation
import NativeAdb

// nearside-spike pair <ip> <pairing port> <code> <debugging port>   pair, then pin the phone's key
// nearside-spike shell <ip> <port> <command>      run a command over wireless debugging
// The key and the phone's pinned TLS key live in %LOCALAPPDATA%\Nearside\spike\.

let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Nearside/spike", isDirectory: true)
let keyFile = folder.appendingPathComponent("adbkey.pem")
let pinFile = folder.appendingPathComponent("phone-key.sha256")

func key() throws -> AdbKey {
    if let pem = FileManager.default.contents(atPath: keyFile.path) { return try AdbKey(pem: pem) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fresh = try AdbKey.generate()
    try fresh.pemData().write(to: keyFile)
    return fresh
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst().map { $0 }
// nearside-spike find   phones advertising wireless debugging (mDNS)
if args.first == "find" {
    let started = Date()
    let found = Discovery.browse(Discovery.connectType)
    print("\(found.count) found in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    for s in found { print("  \(s.name) at \(s.host):\(s.port)") }
    exit(0)
}
guard args.count >= 3, let port = UInt16(args[2]) else {
    fail("usage: nearside-spike pair <ip> <pairing port> <code> <debugging port> | shell <ip> <port> <command>")
}
let host = args[1]

do {
    switch args[0] {
    case "pair" where args.count == 5:
        guard let debugPort = UInt16(args[4]) else { fail("bad debugging port") }
        let key = try key()
        let started = Date()
        let result = try Pairing.pair(host: host, port: port, code: args[3], key: key,
                                      publicKey: try key.androidPublicKey(comment: "nearside-spike@windows"))
        guard let serial = result.serial else { fail("the phone sent no serial") }
        print("paired with \(serial) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        // The debugging service has its own TLS key, so this is trust on first use, not proof of
        // identity: pinned seconds after the code-checked pairing, only if the device reports the
        // paired serial, and only if three connections a second apart all show the same key (a
        // second device answering would show up as a conflict). As the Mac app's pinAfterPairing.
        try? FileManager.default.removeItem(at: pinFile)
        var seen: Data?
        for pass in 0..<3 {
            if pass > 0 { Thread.sleep(forTimeInterval: 1) }
            let adb = try AdbConnection.connect(host: host, port: debugPort, key: key, expectedPeerKey: nil)
            defer { adb.close() }
            let answered = String(decoding: try adb.shell("getprop ro.serialno").stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard answered == serial else { fail("the device at \(host):\(debugPort) isn't the phone that paired; nothing pinned") }
            guard seen == nil || seen == adb.peerKeySHA256 else { fail("different keys answered; nothing pinned") }
            seen = adb.peerKeySHA256
        }
        try seen!.write(to: pinFile)
        print("pinned its debugging key")
    case "shell" where args.count >= 4:
        guard let pin = FileManager.default.contents(atPath: pinFile.path), pin.count == 32 else {
            fail("no pinned phone: pair first")
        }
        let started = Date()
        let adb = try AdbConnection.connect(host: host, port: port, key: try key(), expectedPeerKey: pin)
        defer { adb.close() }
        print("connected (TLS, phone key matches the pin) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        let r = try adb.shell(args[3...].joined(separator: " "))
        print(String(decoding: r.stdout, as: UTF8.self), terminator: "")
        if r.exitCode != 0 { print("exit \(r.exitCode)") }
    default:
        fail("unknown command")
    }
} catch {
    fail("\(error)")
}
