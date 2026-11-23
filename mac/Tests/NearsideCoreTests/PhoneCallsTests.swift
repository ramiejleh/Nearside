import Foundation
import Testing
@testable import NearsideCore

@Suite struct DialableTests {
    @Test func phoneNumbers() {
        #expect(PhoneCalls.dialable("+45 12 34 56 78") == "+4512345678")
        #expect(PhoneCalls.dialable("(555) 123-4567") == "5551234567")
    }

    @Test func notPhoneNumbers() {
        #expect(PhoneCalls.dialable("hello") == nil)
        #expect(PhoneCalls.dialable("12") == nil)
        #expect(PhoneCalls.dialable("1+2345") == nil) // + only first
        #expect(PhoneCalls.dialable("tel:12345") == nil)
        #expect(PhoneCalls.dialable("***") == nil)
        #expect(PhoneCalls.dialable("*21*5551234#") == nil) // call forwarding: never from the Mac
        #expect(PhoneCalls.dialable("*#06#") == nil)
        #expect(PhoneCalls.dialable(String(repeating: "1", count: 21)) == nil)
        #expect(PhoneCalls.dialable("12345;67") == nil)
    }
}

@MainActor @Suite struct PhoneCallsTests {
    private func call(_ key: String = "0|com.google.android.dialer|1|null|10010", state: String = "incoming",
                      can: [String] = ["answer", "decline"], pkg: String = "com.google.android.dialer") -> [String: Any] {
        ["t": "call", "key": key, "pkg": pkg, "app": "Phone", "state": state, "name": "Alex", "can": can,
         "photo": Data([1, 2]).base64EncodedString()]
    }

    @Test func ringingThenOngoingThenEnded() {
        let calls = PhoneCalls()
        var sent: [[String: Any]] = []
        calls.send = { sent.append($0) }
        calls.handle(call())
        let ringing = try! #require(calls.ringing)
        #expect(ringing.state == .incoming && ringing.name == "Alex" && ringing.photo == Data([1, 2]) && calls.ongoing == nil)

        calls.act(.answer, on: ringing)
        #expect(sent.last?["t"] as? String == "call-action" && sent.last?["do"] as? String == "answer")
        // The phone re-posts it as ongoing, without the photo: kept.
        var ongoing = call(state: "ongoing", can: ["hangup"])
        ongoing["photo"] = nil
        calls.handle(ongoing)
        #expect(calls.ringing == nil && calls.ongoing?.photo == Data([1, 2]))

        calls.handle(["t": "call-ended", "key": ringing.key])
        #expect(calls.ongoing == nil && calls.calls.isEmpty)
    }

    @Test func mutedIsUndoneWhenTheCallEnds() {
        let calls = PhoneCalls()
        var sent: [[String: Any]] = []
        calls.send = { sent.append($0) }
        calls.handle(call(state: "ongoing", can: ["hangup"]))
        calls.setMuted(true)
        #expect(calls.muted && sent.last?["t"] as? String == "call-mute" && sent.last?["on"] as? Bool == true)
        calls.handle(["t": "call-ended", "key": calls.ongoing!.key])
        #expect(!calls.muted && sent.last?["on"] as? Bool == false)
    }

    @Test func onlyOffersWhatThePhoneHas() {
        let calls = PhoneCalls()
        var sent: [[String: Any]] = []
        calls.send = { sent.append($0) }
        calls.handle(call(can: ["decline"]))
        calls.act(.answer, on: calls.ringing!)
        #expect(sent.isEmpty)
    }

    @Test func theRingingNumberJoinsThePhoneCallOnly() {
        let calls = PhoneCalls()
        calls.handle(call("voip", pkg: "com.whatsapp"))
        calls.handle(["t": "call-number", "number": "+45 11 22 33 44", "dialer": "com.google.android.dialer"])
        calls.handle(call())
        #expect(calls.calls.first { $0.key == "voip" }?.number == nil)
        #expect(calls.calls.first { $0.package == "com.google.android.dialer" }?.number == "+4511223344")
    }

    @Test func numberMayArriveAfterTheCall() {
        let calls = PhoneCalls()
        calls.handle(call())
        calls.handle(["t": "call-number", "number": "5551234", "dialer": "com.google.android.dialer"])
        #expect(calls.ringing?.number == "5551234")
    }

    @Test func placingChecksTheNumber() {
        let calls = PhoneCalls()
        var sent: [[String: Any]] = []
        calls.send = { sent.append($0) }
        #expect(!calls.place("not a number"))
        #expect(calls.place("555 123 4567"))
        #expect(sent.count == 1 && sent[0]["number"] as? String == "5551234567")
    }

    @Test func refusesBadMessages() {
        #expect(PhoneCall(message: ["key": "k", "state": "exploding"]) == nil)
        #expect(PhoneCall(message: ["state": "incoming"]) == nil)
        let huge = Data(count: 300_000).base64EncodedString()
        #expect(PhoneCall(message: ["key": "k", "state": "incoming", "photo": huge])?.photo == nil)
    }
}

@MainActor @Suite(.serialized) struct CallMuteTests {
    @Test func muteSilencesThisMacsMicrophoneToo() {
        let calls = PhoneCalls()
        calls.handle(["t": "call", "key": "k", "state": "ongoing", "can": ["hangup"]])
        calls.setMuted(true)
        #expect(MicCapture.muted)
        calls.handle(["t": "call-ended", "key": "k"])
        #expect(!MicCapture.muted)
    }
}

@MainActor @Suite struct PinnedCallTests {
    @Test func notPinnedWhileItsAppHasAWindow() {
        let calls = PhoneCalls()
        calls.handle(["t": "call", "key": "k", "pkg": "com.whatsapp", "state": "ongoing", "can": ["hangup"]])
        #expect(calls.pinned?.key == "k")
        calls.windowPackages = ["com.whatsapp"]
        #expect(calls.pinned == nil && calls.ongoing?.key == "k")
        calls.windowPackages = []
        #expect(calls.pinned?.key == "k") // the window closed during the call
    }
}
