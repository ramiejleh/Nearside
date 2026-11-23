import Foundation
import Observation
import os

/// A photo or screenshot on the phone, as its Nearside app lists it (newest 12).
public struct PhonePhoto: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    /// Where it lives on the phone; the Mac pulls it from here with adb when it's taken.
    public let path: String
    public let date: Date
    public let isScreenshot: Bool
    public let width: Int
    public let height: Int
    public let size: Int64

    public init(id: Int64, name: String, path: String, date: Date, isScreenshot: Bool, width: Int, height: Int, size: Int64) {
        self.id = id; self.name = name; self.path = path; self.date = date
        self.isScreenshot = isScreenshot; self.width = width; self.height = height; self.size = size
    }

    /// Pictures only: anything else listed as a photo is ignored, so a click never opens a
    /// document or program from the phone.
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "dng", "avif", "bmp", "tif", "tiff"]

    /// nil for anything that isn't a plain file in the phone's shared storage: the path comes
    /// from the phone, and the Mac reads it with the shell's rights.
    public init?(json: [String: Any]) {
        guard let id = (json["id"] as? NSNumber)?.int64Value,
              let name = json["name"] as? String, !name.isEmpty, !name.contains("/"),
              // The name as it will be saved on the Mac, not just as sent.
              Self.imageExtensions.contains((name as NSString).pathExtension.lowercased()),
              Self.imageExtensions.contains((FileNames.safe(name) as NSString).pathExtension.lowercased()),
              let path = json["path"] as? String, path.hasPrefix("/sdcard/"), path.hasSuffix("/" + name),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
              let millis = (json["date"] as? NSNumber)?.doubleValue else { return nil }
        self.init(id: id, name: name, path: path, date: Date(timeIntervalSince1970: millis / 1000),
                  isScreenshot: json["screenshot"] as? Bool ?? false,
                  width: (json["w"] as? NSNumber)?.intValue ?? 0, height: (json["h"] as? NSNumber)?.intValue ?? 0,
                  size: (json["size"] as? NSNumber)?.int64Value ?? 0)
    }
}

/// The phone's newest photos for the panel's strip, watched only while someone needs them: the
/// panel is open, or new screenshots go to this Mac.
@MainActor
@Observable
public final class RecentPhotos {
    public private(set) var items: [PhonePhoto] = []
    public private(set) var thumbnails: [Int64: Data] = [:]
    /// The phone app may not read photos (the setting is off, or the grant hasn't landed yet).
    public private(set) var denied = false

    /// Sends a message to the phone (set by the engine).
    @ObservationIgnored var send: ([String: Any]) -> Void = { _ in }
    /// A screenshot taken on the phone while watching.
    @ObservationIgnored var onNewScreenshot: ((PhonePhoto) -> Void)?

    @ObservationIgnored private var reasons: Set<String> = []
    /// Ids seen since watching started (nil until the first list): only later ones are new.
    @ObservationIgnored private var seen: Set<Int64>?
    @ObservationIgnored private var connected = false
    @ObservationIgnored private var requested: Set<Int64> = []

    public init() {}

    /// `reason`: "panel", "screenshots". Watching runs while any reason holds.
    func setWatching(_ reason: String, _ on: Bool) {
        let was = !reasons.isEmpty
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
        let now = !reasons.isEmpty
        guard was != now, connected else { return }
        if now { seen = nil }
        send(["t": "photos-watch", "on": now])
    }

    public func panelOpened() { setWatching("panel", true) }
    public func panelClosed() { setWatching("panel", false) }

    /// The phone (and its app) is linked: start watching again if anything wants it.
    func linked() {
        connected = true
        seen = nil
        if !reasons.isEmpty { send(["t": "photos-watch", "on": true]) }
    }

    func connectionLost() {
        connected = false
        items = []
        thumbnails = [:]
        requested = []
    }

    func handle(_ message: [String: Any]) {
        switch message["t"] as? String {
        case "photos":
            denied = message["denied"] as? Bool ?? false
            let list = (message["items"] as? [[String: Any]] ?? []).compactMap(PhonePhoto.init(json:))
            for photo in Self.newScreenshots(seen: seen, in: list) { onNewScreenshot?(photo) }
            seen = (seen ?? []).union(list.map(\.id))
            items = list
            thumbnails = thumbnails.filter { id, _ in list.contains { $0.id == id } }
            // Lists can come in a burst before the first thumbnails do: ask for each one once.
            let missing = list.map(\.id).filter { thumbnails[$0] == nil && !requested.contains($0) }
            requested.formUnion(missing)
            Self.log.info("photos: \(list.count) listed, \(missing.count) thumbnails to fetch\(self.denied ? " (no access)" : "")")
            if !missing.isEmpty { send(["t": "photos-thumbs", "ids": missing.map { NSNumber(value: $0) }]) }
        case "photo-thumb":
            guard let id = (message["id"] as? NSNumber)?.int64Value, items.contains(where: { $0.id == id }),
                  let data = (message["jpeg"] as? String).flatMap({ Data(base64Encoded: $0) }), data.count < 1_000_000 else { return }
            thumbnails[id] = data
        default:
            break
        }
    }

    /// Screenshots in `list` that weren't there before. Nothing is new in the first list (those
    /// were taken before anyone was watching), and old ones that reappear (restored from the
    /// trash) don't count.
    @ObservationIgnored private static let log = Logger(subsystem: "dev.nearside.mac", category: "photos")

    nonisolated static func newScreenshots(seen: Set<Int64>?, in list: [PhonePhoto], now: Date = Date()) -> [PhonePhoto] {
        guard let seen else { return [] }
        return list.filter { $0.isScreenshot && !seen.contains($0.id) && now.timeIntervalSince($0.date) < 120 }
    }
}
