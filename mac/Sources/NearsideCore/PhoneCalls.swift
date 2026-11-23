import Foundation
import Observation

/// A call on the phone, from its call screen's notification (the Phone app's or a VoIP app's).
public struct PhoneCall: Identifiable, Equatable, Sendable {
    public enum State: String, Sendable { case incoming, ongoing, screening }
    public enum Action: String, Sendable { case answer, decline, hangup }

    public let key: String
    public let package: String
    public let app: String
    public let state: State
    public let name: String
    public var photo: Data?
    /// When the call was connected (ongoing calls with a timer).
    public let since: Date?
    public let can: Set<Action>
    /// The caller's number, for a phone call (VoIP calls have none).
    public var number: String?

    public var id: String { key }

    public init?(message: [String: Any]) {
        guard let key = message["key"] as? String, !key.isEmpty,
              let state = (message["state"] as? String).flatMap(State.init(rawValue:)) else { return nil }
        self.key = key
        package = message["pkg"] as? String ?? ""
        app = String((message["app"] as? String ?? "Phone").prefix(60))
        self.state = state
        name = String((message["name"] as? String ?? "").prefix(100))
        photo = (message["photo"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { $0.count <= 256_000 ? $0 : nil }
        since = (message["since"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        can = Set((message["can"] as? [String] ?? []).compactMap(Action.init(rawValue:)))
    }
}

/// The phone's calls: a ringing one for the call panel, an ongoing one for the in-call card under
/// the menu-bar icon. Answering, declining and hanging up press the phone's own call buttons; the
/// phone keeps its call screen.
@MainActor @Observable
public final class PhoneCalls {
    public private(set) var calls: [PhoneCall] = []
    /// The call can't hear you (from here): the phone's microphone, and this Mac's for calls in
    /// a phone window.
    public private(set) var muted = false {
        didSet { MicCapture.muted = muted }
    }
    /// The ringing phone call's number and the dialer it rings in (from the helper).
    private var ringingNumber: (number: String, dialer: String)?
    @ObservationIgnored public var send: ([String: Any]) -> Void = { _ in }

    public init() {}

    /// The call ringing now (or being screened).
    public var ringing: PhoneCall? { calls.first { $0.state != .ongoing } }
    /// The call in progress, wherever it was answered.
    public var ongoing: PhoneCall? { calls.first { $0.state == .ongoing } }
    /// Phone apps open in Mac windows (set by the window manager).
    public var windowPackages: Set<String> = []
    /// The call in progress, for the card under the menu-bar icon: not when its app has a Mac
    /// window, which shows the call itself.
    public var pinned: PhoneCall? { ongoing.flatMap { windowPackages.contains($0.package) ? nil : $0 } }

    public func handle(_ message: [String: Any]) {
        switch message["t"] as? String {
        case "call":
            guard var call = PhoneCall(message: message) else { return }
            let old = calls.first { $0.key == call.key }
            call.number = old?.number ?? ringingNumber(for: call)
            // The photo is sent once per call.
            if call.photo == nil { call.photo = old?.photo }
            calls.removeAll { $0.key == call.key }
            calls.append(call)
        case "call-ended":
            guard let key = message["key"] as? String else { return }
            calls.removeAll { $0.key == key }
            if ongoing == nil, muted { setMuted(false) } // never leave the phone muted
        case "call-muted":
            // The phone kept a mute through the link dropping: show it (without sending it back).
            muted = message["on"] as? Bool ?? false
        case "call-number":
            if let number = message["number"] as? String, let dialable = Self.dialable(number) {
                ringingNumber = (dialable, message["dialer"] as? String ?? "")
                for i in calls.indices where calls[i].number == nil {
                    calls[i].number = ringingNumber(for: calls[i])
                }
            } else {
                ringingNumber = nil
            }
        default:
            break
        }
    }

    private func ringingNumber(for call: PhoneCall) -> String? {
        guard let ringing = ringingNumber, call.state == .incoming,
              ringing.dialer.isEmpty || call.package == ringing.dialer else { return nil }
        return ringing.number
    }

    public func act(_ action: PhoneCall.Action, on call: PhoneCall) {
        guard call.can.contains(action) else { return }
        send(["t": "call-action", "key": call.key, "do": action.rawValue])
    }

    /// Mutes or unmutes the phone's microphone and this Mac's (for any call).
    public func setMuted(_ on: Bool) {
        muted = on
        send(["t": "call-mute", "on": on])
    }

    /// Calls `number` from the phone.
    @discardableResult
    public func place(_ number: String) -> Bool {
        guard let dialable = Self.dialable(number) else { return false }
        send(["t": "call-place", "number": dialable])
        return true
    }

    /// The link went: the phone sends its calls again when it's back.
    public func connectionLost() {
        calls = []
        // The phone keeps its microphone muted until the call ends, and says so when it's back;
        // this Mac's microphone only goes to windows, which close with the link.
        muted = false
        ringingNumber = nil
    }

    /// A phone number: digits with an optional leading +, spaces and dashes dropped; nil for
    /// anything else. The phone checks the same.
    public nonisolated static func dialable(_ text: String) -> String? {
        let kept = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !" -().\u{a0}".contains($0) }
        guard (3...20).contains(kept.count) else { return nil }
        // Never * or #: those make service codes (call forwarding, …) that change the phone's settings.
        for (i, c) in kept.enumerated() {
            guard ("0"..."9").contains(c) || (c == "+" && i == 0) else { return nil }
        }
        guard kept.contains(where: { ("0"..."9").contains($0) }) else { return nil }
        return kept
    }
}
