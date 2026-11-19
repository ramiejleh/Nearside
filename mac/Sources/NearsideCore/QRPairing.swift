import Foundation

/// Android's "Pair device with QR code" flow (the one Android Studio uses):
/// the Mac shows `WIFI:T:ADB;S:<name>;P:<password>;;`, the phone scans it and advertises
/// `_adb-tls-pairing._tcp` under `<name>`, and the Mac then runs `adb pair <addr> <password>`.
public struct QRPairing: Sendable, Equatable {
    public let name: String
    public let password: String

    public init(name: String, password: String) {
        self.name = name
        self.password = password
    }

    /// Letters and digits only, so nothing needs escaping in the QR text.
    public static func random() -> QRPairing {
        func token(_ length: Int) -> String {
            let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
            return String((0..<length).map { _ in alphabet.randomElement()! })
        }
        return QRPairing(name: "nearside-\(token(8))", password: token(12))
    }

    public var payload: String { "WIFI:T:ADB;S:\(name);P:\(password);;" }
}
