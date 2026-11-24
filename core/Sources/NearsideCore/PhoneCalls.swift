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
        didSet { MicrophoneMute.muted = muted }
    }
    /// The ringing phone call's number and the dialer it rings in (from the helper).
    private var ringingNumber: (number: String, dialer: String)?
    @ObservationIgnored public var send: ([String: Any]) -> Void = { _ in }

    public init() {}

    /// The call ringing now (or being screened).
    public var ringing: PhoneCall? { calls.first { $0.state != .ongoing } }
    /// The call in progress, wherever it was answered.
    public var ongoing: PhoneCall? { calls.first { $0.state == .ongoing } }
    /// Phone apps open in Mac windows (set by the window manager). A phone call with the Phone
    /// app open here talks through this Mac.
    public var windowPackages: Set<String> = [] {
        didSet {
            // The Phone app opened here during a phone call: talk here (closing it keeps it here;
            // "Open on Phone" moves it back).
            if let call = ongoing, windowPackages.contains(call.package), !oldValue.contains(call.package) { wantOnMac.insert(call.key) }
            routeAudio()
        }
    }

    /// The phone call's sound and microphone are on this Mac (else on the phone).
    public private(set) var audioOnMac = false
    /// Calls (by key) answered or moved here: their sound comes here once they connect.
    private var wantOnMac: Set<String> = []
    /// A call placed from here, until then: the next outgoing call talks here.
    private var placedUntil = Date.distantPast
    /// Calls seen ringing in: never taken as the one placed from here.
    private var seenIncoming: Set<String> = []
    /// Calls moved to the phone from here: they stay there even with the Phone app open here.
    private var movedToPhone: Set<String> = []
    /// The phone's dialer (from the helper), to tell phone calls from app calls.
    private var dialer = ""
    /// Moves the phone call's sound to this Mac (true) or back to the phone.
    @ObservationIgnored public var onAudioRoute: (Bool) -> Void = { _ in }

    /// A phone call (cellular), whose sound needs the call stream; app calls use their window's.
    public func isPhoneCall(_ call: PhoneCall) -> Bool {
        call.number != nil || call.package == dialer || call.package.hasSuffix(".dialer")
    }

    /// The card's button: the call's sound to this Mac, or back to the phone.
    public func moveAudio(toMac: Bool) {
        if let key = ongoing?.key {
            if toMac { wantOnMac.insert(key); movedToPhone.remove(key) } else { wantOnMac.remove(key); movedToPhone.insert(key) }
        }
        if !toMac { setAudio(false) } else { routeAudio() }
    }

    /// The call stream ended on its own (the call ended, or the Mac couldn't take it).
    public func audioEnded() {
        audioOnMac = false
        if let key = ongoing?.key { wantOnMac.remove(key) }
    }

    private func routeAudio() {
        guard let call = ongoing, isPhoneCall(call), !audioOnMac else { return }
        let placedHere = !seenIncoming.contains(call.key) && Date() < placedUntil
        if placedHere { placedUntil = .distantPast; wantOnMac.insert(call.key) }
        if wantOnMac.contains(call.key) || windowPackages.contains(call.package) && !movedToPhone.contains(call.key) { setAudio(true) }
    }

    private func setAudio(_ on: Bool) {
        guard on != audioOnMac else { return }
        audioOnMac = on
        onAudioRoute(on)
    }
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
            if call.state != .ongoing { seenIncoming.insert(call.key) }
            routeAudio()
        case "call-ended":
            guard let key = message["key"] as? String else { return }
            calls.removeAll { $0.key == key }
            wantOnMac.remove(key); movedToPhone.remove(key); seenIncoming.remove(key)
            if ongoing == nil {
                if muted { setMuted(false) } // never leave the phone muted
                setAudio(false)
            }
        case "call-muted":
            // The phone kept a mute through the link dropping: show it (without sending it back).
            muted = message["on"] as? Bool ?? false
        case "call-number":
            if let number = message["number"] as? String, let dialable = Self.dialable(number) {
                ringingNumber = (dialable, message["dialer"] as? String ?? "")
                if let d = message["dialer"] as? String, !d.isEmpty { dialer = d }
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
        if action == .answer, isPhoneCall(call) { wantOnMac.insert(call.key) }
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
        placedUntil = Date().addingTimeInterval(60) // the call it starts talks here
        send(["t": "call-place", "number": dialable])
        return true
    }

    /// The phone's call notifications still showing (after a catch-up): any other call has ended.
    public func keepOnly(_ keys: Set<String>) {
        for call in calls where !keys.contains(call.key) { handle(["t": "call-ended", "key": call.key]) }
    }

    /// The link went: the phone sends its calls again when it's back.
    public func connectionLost() {
        calls = []
        setAudio(false) // the call stream goes with the link
        wantOnMac = []; movedToPhone = []; seenIncoming = []; placedUntil = .distantPast
        // The mute stays (fail closed): phone-app windows can outlive a brief drop, and the phone
        // says whether it's still muted when it's back ("call-muted").
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
