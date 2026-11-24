import AppKit
import Foundation
import Network
import NearsideCore

/// The engine's view of this Mac (see `Platform`). The app installs it first thing at launch.
public final class MacPlatform: Platform, @unchecked Sendable {
    public init() {}

    public var computerName: String { Host.current().localizedName ?? "Mac" }

    public var bundledPhoneAppVersion: Int? {
        Bundle.main.object(forInfoDictionaryKey: "NearsidePhoneAppVersion") as? Int
    }

    @MainActor public func makeClipboard(onCopy: @escaping @MainActor (String) -> Void) -> any Clipboard {
        PasteboardWatcher(onCopy: onCopy)
    }

    @MainActor public func makeNotifications() -> any SystemNotifications { PhoneNotifications() }

    @MainActor public func makeScreenshotWatcher() -> any ScreenshotWatcher { MacScreenshots() }

    @MainActor private var network: NWPathMonitor?

    @MainActor public func watchReachability(_ changed: @escaping @MainActor () -> Void) {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in changed() }
        }
        monitor.start(queue: .main)
        network = monitor
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { changed() }
        }
    }

    @MainActor public func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Quarantined like a browser or AirDrop download, so Gatekeeper checks it first.
    public func markDownloaded(_ url: URL) -> Bool {
        let flags = "0083" // downloaded, Gatekeeper must check
        let value = "\(flags);\(String(Int(Date().timeIntervalSince1970), radix: 16));Nearside;\(UUID().uuidString)"
        return value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) } == 0
    }

    public var preferredCodec: DisplayWire.Codec { VideoDecoder.preferredCodec }

    public func makeVideoDecoder(codec: DisplayWire.Codec) -> any VideoDecoding { VideoDecoder(codec: codec) }

    public func makeAudioOutput() -> any AudioOutput { AudioPlayer() }

    public func makeMicrophone() -> any Microphone { MicCapture() }

    public func microphoneAllowed() async -> Bool { await MicCapture.allowed() }
}
