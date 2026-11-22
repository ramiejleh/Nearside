import Foundation

/// The phone's battery, signal and network, as its Nearside app reports them
/// (`{"t":"phone-status",…}`, sent only when something here changes).
public struct PhoneStatus: Equatable, Sendable {
    /// 0–100.
    public var battery: Int
    public var charging: Bool
    /// Signal bars 0–4; nil without a SIM.
    public var signal: Int?
    /// What the phone's status bar shows: "5G", "LTE", "3G", "2G"; nil when unknown.
    public var network: String?
    public var wifi: Bool

    public init(battery: Int, charging: Bool, signal: Int?, network: String?, wifi: Bool) {
        self.battery = battery
        self.charging = charging
        self.signal = signal
        self.network = network
        self.wifi = wifi
    }

    /// nil when the message has no usable battery level.
    public init?(message: [String: Any]) {
        guard let battery = (message["battery"] as? NSNumber)?.intValue, (0...100).contains(battery) else { return nil }
        self.battery = battery
        charging = message["charging"] as? Bool ?? false
        signal = (message["signal"] as? NSNumber).map { min(4, max(0, $0.intValue)) }
        // Only short labels: the text comes from the phone and goes into the menu bar.
        network = (message["network"] as? String).flatMap { $0.count <= 4 && !$0.isEmpty ? $0 : nil }
        wifi = message["wifi"] as? Bool ?? false
    }

    /// The low-battery notice: once when the battery drops to `threshold` or below while not
    /// charging, then not again until it charges or climbs back above `threshold + 5`.
    public struct LowBatteryAlert: Equatable, Sendable {
        public static let threshold = 20
        public private(set) var warned = false

        public init() {}

        /// True when the notice should be shown now.
        public mutating func update(_ status: PhoneStatus) -> Bool {
            if status.charging || status.battery > Self.threshold + 5 {
                warned = false
                return false
            }
            guard !warned, status.battery <= Self.threshold else { return false }
            warned = true
            return true
        }
    }
}
