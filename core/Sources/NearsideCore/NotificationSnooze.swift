import Foundation

/// "Mute notifications": while it's on, the phone's notifications arrive as usual (the phone
/// window's list keeps them) but aren't shown on this computer. When it ends, the ones still on
/// the phone are shown: the newest few as banners, the rest straight into the notification list.
public struct NotificationSnooze: Equatable, Sendable {
    /// Banners when it ends, as many as a reconnect's catch-up shows.
    public static let banners = 3
    /// The lengths offered, in hours.
    public static let hours = [1, 2, 4, 8, 24]

    /// When it ends; `.distantFuture` until it's turned off.
    public private(set) var until: Date?
    /// What arrived meanwhile, by key: whether it was quiet (the phone had sent it before).
    private var held: [String: Bool] = [:]

    public init(until: Date? = nil) { self.until = until }

    public func isOn(at now: Date = Date()) -> Bool { until.map { now < $0 } ?? false }
    public var isIndefinite: Bool { until == .distantFuture }

    public mutating func start(until date: Date) { until = date }

    public mutating func hold(_ key: String, quiet: Bool) {
        held[key] = (held[key] ?? true) && quiet // loud once, loud when shown
    }

    public mutating func drop(_ key: String) { held[key] = nil }
    public mutating func keepOnly(_ keys: Set<String>) { held = held.filter { keys.contains($0.key) } }
    public mutating func forgetHeld() { held = [:] }

    /// Ends it: the held ones still in `current` (newest first), each with whether to show it quietly.
    public mutating func end(current: [PhoneNotification]) -> [(PhoneNotification, quiet: Bool)] {
        let waiting = current.filter { held[$0.key] != nil }.sorted { $0.posted > $1.posted }
        var banners = 0
        let out = waiting.map { note -> (PhoneNotification, quiet: Bool) in
            let loud = held[note.key] == false && banners < Self.banners
            if loud { banners += 1 }
            return (note, !loud)
        }
        until = nil
        held = [:]
        return out
    }
}
