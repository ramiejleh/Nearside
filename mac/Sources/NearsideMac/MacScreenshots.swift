import Foundation
import NearsideCore

/// New screenshots taken on this Mac, found through Spotlight (`kMDItemIsScreenCapture`), so it
/// works whatever the language or the save location. Only ones taken while it's on count.
@MainActor
final class MacScreenshots: ScreenshotWatcher {
    var onNew: ((URL) -> Void)?

    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            if isOn { start() } else { stop() }
        }
    }

    private var query: NSMetadataQuery?
    private var since = Date()
    private var sent: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private var retry: Timer?

    /// Where macOS saves screenshots: the Desktop unless changed in the Screenshot app.
    static var folder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !location.isEmpty else {
            return home.appendingPathComponent("Desktop", isDirectory: true)
        }
        return URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
    }

    private func start() {
        // Spotlight leaves out files this app may not read, and the Desktop is protected: reading
        // the folder makes macOS ask for access (only the first time). Until it's allowed, look
        // again every few seconds, then start over so the query sees the folder.
        if (try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path)) == nil {
            retry?.invalidate()
            retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isOn,
                          (try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path)) != nil else { return }
                    self.stop() // also ends this timer
                    self.start()
                }
            }
        }
        since = Date()
        sent = []
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemContentCreationDate >= %@", since as NSDate)
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] note in
                let added = (note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem]) ?? []
                let changed = (note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem]) ?? []
                let paths = (added + changed).compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
                MainActor.assumeIsolated { self?.found(paths) }
            },
        ]
        query.start()
        self.query = query
    }

    private func stop() {
        retry?.invalidate()
        retry = nil
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func found(_ paths: [String]) {
        for path in paths where !sent.contains(path) {
            // The screenshot thumbnail in the corner writes the file a moment later; skip
            // anything not there yet (it comes back as "changed").
            guard FileManager.default.fileExists(atPath: path) else { continue }
            sent.insert(path)
            onNew?(URL(fileURLWithPath: path))
        }
    }
}
