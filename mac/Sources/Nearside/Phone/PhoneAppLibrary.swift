import NearsideCore
import NearsideMac
import AppKit
import Observation

/// The phone's apps as the launcher, Dock menu, windows and Spotlight show them: the list (kept on
/// disk, so it's there at once and while the phone is away), their icons, favourites and recents.
@MainActor @Observable
final class PhoneAppLibrary {
    enum Status: Equatable { case idle, loading, failed }

    private(set) var apps: [PhoneApp] = []
    private(set) var icons: [String: NSImage] = [:]
    private(set) var status: Status = .idle
    private(set) var favourites: [String] = UserDefaults.standard.stringArray(forKey: "PhoneApps.favourites") ?? []

    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// Each icon's PNG as it was drawn from: an icon that comes again unchanged isn't redrawn.
    @ObservationIgnored private var iconSources: [String: Data] = [:]
    /// When the phone's list last came: opening the launcher again soon after doesn't ask again.
    @ObservationIgnored private var refreshedAt = Date.distantPast
    @ObservationIgnored private static let file = Paths.support.appendingPathComponent("phone-apps.json")
    /// Called with the list whenever it changes (Spotlight indexing).
    @ObservationIgnored var onChange: (([PhoneApp]) -> Void)?

    init(engine: SyncEngine) {
        self.engine = engine
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode([PhoneApp].self, from: data) {
            apps = saved
            for app in saved { if let icon = PhoneIconCache.cached(app) { setIcon(icon, for: app.id) } }
        }
    }

    /// Fetches the list (and any icons not cached yet) from the phone.
    func refresh() {
        // Every open of the launcher asks; once a minute is plenty for apps installed or removed.
        guard refreshing == nil, apps.isEmpty || status == .failed || Date().timeIntervalSince(refreshedAt) > 60 else { return }
        status = .loading
        refreshing = Task { [weak self] in
            guard let self else { return }
            defer { refreshing = nil }
            guard let fresh = await engine.phoneApps() else {
                status = apps.isEmpty ? .failed : .idle
                return
            }
            // A Mac window opened just now counts as use even before the phone's stats say so.
            let local = Dictionary(apps.compactMap { a in a.lastUsed.map { (a.id, $0) } }, uniquingKeysWith: max)
            let merged = fresh.map { app in
                var app = app
                if let mine = local[app.id], mine > (app.lastUsed ?? .distantPast) { app.lastUsed = mine }
                return app
            }
            refreshedAt = Date()
            status = .idle
            // Only a real change redraws the launcher and re-indexes Spotlight and Applications.
            var changed = merged != apps
            if changed {
                apps = merged
                if let data = try? JSONEncoder().encode(apps) { try? data.write(to: Self.file, options: .atomic) }
            }
            await engine.phoneAppIcons(for: apps) { batch in
                for (id, icon) in batch where self.setIcon(icon, for: id) { changed = true }
            }
            if changed { onChange?(apps) }
        }
    }

    func app(id: String) -> PhoneApp? { apps.first { $0.id == id } }
    func app(package: String) -> PhoneApp? { apps.first { $0.package == package } }

    /// The most recently used apps, newest first.
    func recents(_ n: Int = 8) -> [PhoneApp] {
        Array(apps.filter { $0.lastUsed != nil }.sorted { $0.lastUsed! > $1.lastUsed! }.prefix(n))
    }

    func favouriteApps() -> [PhoneApp] { favourites.compactMap { app(id: $0) } }

    func isFavourite(_ app: PhoneApp) -> Bool { favourites.contains(app.id) }

    func toggleFavourite(_ app: PhoneApp) {
        if let i = favourites.firstIndex(of: app.id) { favourites.remove(at: i) } else { favourites.append(app.id) }
        UserDefaults.standard.set(favourites, forKey: "PhoneApps.favourites")
    }

    func markUsed(_ app: PhoneApp) {
        guard let i = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[i].lastUsed = Date()
    }

    /// Apps matching `query`: names starting with it, then words starting with it, then containing it.
    func search(_ query: String) -> [PhoneApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        func rank(_ app: PhoneApp) -> Int? {
            let label = app.label
            if label.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { return 0 }
            let words = label.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if words.contains(where: { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }) { return 1 }
            if label.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return 2 }
            return nil
        }
        return apps.compactMap { app in rank(app).map { (app, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// The icon, or a plain placeholder until it's here.
    func icon(_ app: PhoneApp) -> NSImage { icons[app.id] ?? Self.placeholder }

    func hasIcon(_ app: PhoneApp) -> Bool { icons[app.id] != nil }

    /// Draws `icon` for `id` unless it's the one already drawn; true if it changed.
    @discardableResult
    private func setIcon(_ icon: PhoneAppIcon, for id: String) -> Bool {
        guard iconSources[id] != icon.png, let image = Self.image(icon) else { return false }
        iconSources[id] = icon.png
        icons[id] = image
        return true
    }

    func iconPNG(_ app: PhoneApp) -> Data? {
        guard let image = icons[app.id], let tiff = image.tiffRepresentation(using: .none, factor: 1) else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    // MARK: Drawing

    /// macOS's icon grid: the shape fills 824 of 1024, centred, with a continuous corner.
    private static let inset: CGFloat = 100.0 / 1024

    /// Adaptive icons get the Mac's rounded square (with its soft shadow), and so do old-style
    /// icons that fill their square edge to edge; others are drawn as the phone made them, in the
    /// same box.
    private static func image(_ icon: PhoneAppIcon) -> NSImage? {
        guard let bitmap = NSImage(data: icon.png) else { return nil }
        let shaped = icon.adaptive || isFullSquare(icon.png)
        let image = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            let box = rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)
            guard shaped else {
                bitmap.draw(in: box)
                return true
            }
            let shape = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.28)
            shadow.shadowOffset = NSSize(width: 0, height: -rect.height * 0.01)
            shadow.shadowBlurRadius = rect.height * 0.02
            shadow.set()
            NSColor.white.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            bitmap.draw(in: box)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        return flattened(image)
    }

    /// Drawn once into a bitmap (at 2x): the launcher's grid then draws pixels, not the shape and
    /// shadow again for every icon on every redraw.
    private static func flattened(_ image: NSImage) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = image.size // before the context: it takes its coordinates (points, at 2x) from it
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        let flat = NSImage(size: image.size)
        flat.addRepresentation(rep)
        return flat
    }

    /// Opaque in all four corners: a square picture rather than a shape on transparency.
    private static func isFullSquare(_ png: Data) -> Bool {
        guard let rep = NSBitmapImageRep(data: png), rep.pixelsWide > 8, rep.pixelsHigh > 8 else { return false }
        let w = rep.pixelsWide - 3, h = rep.pixelsHigh - 3
        return [(2, 2), (w, 2), (2, h), (w, h)].allSatisfy { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) > 0.95 }
    }

    private static let placeholder: NSImage = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
        let box = rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)
        NSColor(white: 0.55, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225).fill()
        return true
    }
}
