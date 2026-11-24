import Foundation

/// What the engine needs from the computer it runs on (the Mac app or the Windows app): the
/// clipboard, system notifications, the screenshots folder, files, audio, the microphone and video
/// decoding. Set `Platform.current` once at launch, before anything else in this module runs.
public protocol Platform: AnyObject, Sendable {
    /// This computer's name, as the phone shows it ("in use on …").
    var computerName: String { get }
    /// Sent in the helper hello: "windows" on a PC, nil on a Mac.
    var osName: String? { get }
    /// The phone app bundled with this app (its versionCode), to update the phone's when older.
    var bundledPhoneAppVersion: Int? { get }

    @MainActor func makeClipboard(onCopy: @escaping @MainActor (String) -> Void) -> any Clipboard
    @MainActor func makeNotifications() -> any SystemNotifications
    @MainActor func makeScreenshotWatcher() -> any ScreenshotWatcher
    /// Network changes and the computer waking up: the phone may be reachable again.
    @MainActor func watchReachability(_ changed: @escaping @MainActor () -> Void)
    /// Shows a file in Finder / Explorer.
    @MainActor func reveal(_ url: URL)
    /// Marks a file from the phone as downloaded (quarantine / Mark of the Web), so the system
    /// checks it before anything in it can run. False if it couldn't (the file is then deleted).
    func markDownloaded(_ url: URL) -> Bool

    /// The codec this computer decodes best.
    var preferredCodec: DisplayWire.Codec { get }
    func makeVideoDecoder(codec: DisplayWire.Codec) -> any VideoDecoding
    func makeAudioOutput() -> any AudioOutput
    func makeMicrophone() -> any Microphone
    /// Whether this computer may use its microphone (asking the first time).
    func microphoneAllowed() async -> Bool
}

extension Platform {
    public var osName: String? { nil }
}

public enum Platforms {
    nonisolated(unsafe) private static var installed: (any Platform)?
    /// The running app's platform. Setting it is the first thing the app does.
    public static var current: any Platform {
        get {
            guard let installed else { fatalError("Platforms.current isn't set: the app sets it at launch") }
            return installed
        }
        set { installed = newValue }
    }
}

@MainActor
public protocol Clipboard: AnyObject {
    /// Starts watching: each new copy on this computer goes to `onCopy`.
    func start()
    /// Puts text from the phone on this computer's clipboard (not reported back as a copy).
    func write(_ text: String)
}

@MainActor
public protocol ScreenshotWatcher: AnyObject {
    var onNew: ((URL) -> Void)? { get set }
    var isOn: Bool { get set }
}

/// The phone's notifications as system notifications, plus this app's own.
@MainActor
public protocol SystemNotifications: AnyObject {
    var onDismiss: ((String) -> Void)? { get set }
    var onOpen: ((String) -> Void)? { get set }
    /// A button (index), with the text typed for a reply.
    var onAction: ((String, Int, String?) -> Void)? { get set }
    /// Open in a window on this computer: (key, package, app name).
    var onOpenOnMac: ((String, String, String) -> Void)? { get set }
    func activate()
    func show(key: String, package: String, app: String, title: String, text: String,
              iconPNG: Data?, actions: [PhoneNotification.Action], quiet: Bool)
    func showLocal(id: String, title: String, body: String)
    func remove(key: String)
    /// Notices ones cleared on this computer (and dismisses them on the phone).
    func reconcile()
    func keepOnly(_ keys: Set<String>)
    func removeAll()
}

/// A decoded picture. The platform's own type (a CVPixelBuffer on the Mac) is behind it.
public protocol VideoFrame: Sendable {
    var gen: UInt32 { get }
    var ptsMicros: Int64 { get }
    var receivedMicros: Int64 { get }
    /// All black (an app blocking capture shows black): samples the picture.
    func isBlack() -> Bool
}

/// Annex-B video in (as the phone's encoder emits), frames out to `onFrame`. Fed from one thread.
public protocol VideoDecoding: AnyObject, Sendable {
    var codec: DisplayWire.Codec { get }
    var gen: UInt32 { get }
    var onFrame: (@Sendable (any VideoFrame) -> Void)? { get set }
    /// New parameter sets (first frame, or after a resize restarted the encoder). False if unusable.
    @discardableResult func configure(parameterSets annexB: Data, gen: UInt32) -> Bool
    func decode(annexB: Data, gen: UInt32, ptsMicros: Int64, receivedMicros: Int64)
    func invalidate()
}

/// A window's sound (Opus from the phone) or a call's, played on this computer.
public protocol AudioOutput: AnyObject, Sendable {
    func configure(sampleRate: Int, channels: Int)
    func play(_ packet: Data, ptsMicros: Int64, receivedMicros: Int64)
    /// The phone went quiet: play out what's buffered.
    func silence()
    /// (packets, underruns, dropped frames, buffered frames), for the stats log.
    var stats: (packets: Int, underruns: Int, dropped: Int, buffered: Int) { get }
    func stop()
}

/// This computer's microphone, as 20 ms chunks of 48 kHz mono 16-bit PCM (`DisplayWire.micSampleRate`).
/// Silence goes instead while `MicrophoneMute.muted`.
public protocol Microphone: AnyObject, Sendable {
    /// 20 ms of samples, on the audio thread. Set before start().
    var onChunk: (Data) -> Void { get set }
    /// The phone's app started (or stopped) recording.
    func want(_ on: Bool)
    /// False if the microphone can't be opened (true, doing nothing, if it isn't wanted).
    @discardableResult func start() -> Bool
    func stop()
}

/// Muted from the in-call card: every microphone sends silence, so the call hears nothing.
public enum MicrophoneMute {
    public static var muted: Bool {
        get { lock.withLock { _muted } }
        set { lock.withLock { _muted = newValue } }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _muted = false
}
