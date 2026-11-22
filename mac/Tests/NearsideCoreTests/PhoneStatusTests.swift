import Testing
@testable import NearsideCore

@Suite struct PhoneStatusTests {
    @Test func parsesTheMessage() {
        let status = PhoneStatus(message: ["t": "phone-status", "battery": 82, "charging": true,
                                           "signal": 3, "network": "5G", "wifi": true])
        #expect(status == PhoneStatus(battery: 82, charging: true, signal: 3, network: "5G", wifi: true))
    }

    @Test func optionalFieldsAndBounds() {
        let noSim = PhoneStatus(message: ["battery": 40])
        #expect(noSim == PhoneStatus(battery: 40, charging: false, signal: nil, network: nil, wifi: false))
        #expect(PhoneStatus(message: ["battery": 50, "signal": 9])?.signal == 4)
        #expect(PhoneStatus(message: ["battery": 50, "network": "a very long label"])?.network == nil)
        #expect(PhoneStatus(message: ["battery": 101]) == nil)
        #expect(PhoneStatus(message: ["charging": true]) == nil)
    }

    @Test func lowBatteryWarnsOncePerDrop() {
        var alert = PhoneStatus.LowBatteryAlert()
        func at(_ battery: Int, charging: Bool = false) -> Bool {
            alert.update(PhoneStatus(battery: battery, charging: charging, signal: nil, network: nil, wifi: true))
        }
        #expect(!at(30))
        #expect(at(20))         // reaches the threshold: warn
        #expect(!at(19))        // not again on the way down
        #expect(!at(22))        // a small bounce doesn't re-arm it
        #expect(!at(18))
        #expect(!at(18, charging: true)) // charging re-arms it
        #expect(at(17))
        #expect(!at(30))        // well above re-arms it too
        #expect(at(15))
    }

    @Test func noWarningWhileCharging() {
        var alert = PhoneStatus.LowBatteryAlert()
        let warned = alert.update(PhoneStatus(battery: 5, charging: true, signal: 2, network: "LTE", wifi: false))
        #expect(!warned)
    }
}
