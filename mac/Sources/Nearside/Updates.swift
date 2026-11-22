import Foundation
import Sparkle

/// App updates through Sparkle. Only release builds have them: `release.sh` writes the feed URL
/// and the EdDSA public key into Info.plist, and without both the updater never starts (a
/// development build mustn't offer to replace itself with a release).
@MainActor
enum Updates {
    static let available: Bool = {
        let info = Bundle.main.infoDictionary ?? [:]
        return !((info["SUFeedURL"] as? String) ?? "").isEmpty
            && !((info["SUPublicEDKey"] as? String) ?? "").isEmpty
    }()

    private static let controller: SPUStandardUpdaterController? = available
        ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        : nil

    /// Starts the updater (it checks by itself once a day, after asking the first time).
    static func start() { _ = controller }

    static func checkNow() { controller?.checkForUpdates(nil) }

    static var automaticChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
