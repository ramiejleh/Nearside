import Foundation

/// One of the phone's current notifications, as the phone app sends it (NotificationMirror).
/// Ongoing ones (music, navigation) and group summaries aren't sent.
public struct PhoneNotification: Identifiable, Equatable, Sendable {
    public struct Action: Equatable, Sendable {
        public let title: String
        /// Takes typed text (a reply).
        public let isReply: Bool
    }

    /// The phone's notification key.
    public let key: String
    public let package: String
    /// The app's name.
    public let app: String
    public let title: String
    public let text: String
    public let posted: Date
    public let actions: [Action]

    public var id: String { key }

    /// The app's icon as the phone sent it with its first notification (cached per package).
    public static func iconURL(package: String) -> URL? {
        let safe = package.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
        guard !safe.isEmpty else { return nil }
        let url = Paths.support.appendingPathComponent("icons", isDirectory: true).appendingPathComponent("\(safe).png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
