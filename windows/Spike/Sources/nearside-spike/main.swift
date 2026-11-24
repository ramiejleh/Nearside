import Foundation
import NativeAdb

// nearside-spike pair <ip> <pairing port> <code>   pair this computer's key with the phone
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
guard args.count >= 3, let port = UInt16(args[2]) else {
    fail("usage: nearside-spike pair <ip> <port> <code> | shell <ip> <port> <command>")
}
let host = args[1]

do {
    switch args[0] {
    case "pair" where args.count == 4:
        let key = try key()
        let started = Date()
        let result = try Pairing.pair(host: host, port: port, code: args[3], key: key,
                                      publicKey: try key.androidPublicKey(comment: "nearside-spike@windows"))
        try? FileManager.default.removeItem(at: pinFile) // pinned on the first connection (as the Mac app does)
        print("paired with \(result.serial ?? "?") in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    case "shell" where args.count >= 4:
        let pin = FileManager.default.contents(atPath: pinFile.path)
        let started = Date()
        let adb = try AdbConnection.connect(host: host, port: port, key: try key(), expectedPeerKey: pin)
        defer { adb.close() }
        if pin == nil { try adb.peerKeySHA256.write(to: pinFile) }
        print("connected (TLS, phone key \(pin == nil ? "pinned now" : "matches the pin")) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        let r = try adb.shell(args[3...].joined(separator: " "))
        print(String(decoding: r.stdout, as: UTF8.self), terminator: "")
        if r.exitCode != 0 { print("exit \(r.exitCode)") }
    default:
        fail("unknown command")
    }
} catch {
    fail("\(error)")
}
