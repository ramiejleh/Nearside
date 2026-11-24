import Foundation
import NearsideCore
#if os(Windows)
import WinSDK
#endif

// The engine's view of a Windows PC: the clipboard and Mark of the Web here; notifications,
// video and sound from whoever runs the engine (the app's bridge, or a test tool).

public final class WindowsPlatform: Platform, @unchecked Sendable {
    /// The decoder; nil where there's no video (the console tool).
    public var videoDecoder: ((DisplayWire.Codec) -> any VideoDecoding)?
    /// Shows the phone's notifications; printed (app name only) if not set.
    public var notifications: (@MainActor () -> any SystemNotifications)?
    public init() {}

    public var computerName: String { ProcessInfo.processInfo.hostName }
    public var osName: String? { "windows" }
    public var bundledPhoneAppVersion: Int? { nil } // don't update the phone app from here
    @MainActor public func makeClipboard(onCopy: @escaping @MainActor (String) -> Void) -> any Clipboard { WindowsClipboard(onCopy: onCopy) }
    @MainActor public func makeNotifications() -> any SystemNotifications { notifications?() ?? PrintedNotifications() }
    @MainActor public func makeScreenshotWatcher() -> any ScreenshotWatcher { NoScreenshots() }
    @MainActor public func watchReachability(_ changed: @escaping @MainActor () -> Void) {}
    /// Opens the folder in Explorer with the file selected.
    @MainActor public func reveal(_ url: URL) {
        #if os(Windows)
        url.path.replacingOccurrences(of: "/", with: "\\").withCString(encodedAs: UTF16.self) { path in
            guard let item = ILCreateFromPathW(path) else { return }
            defer { ILFree(item) }
            _ = SHOpenFolderAndSelectItems(item, 0, nil, 0)
        }
        #endif
    }
    /// Mark of the Web, as a browser download gets: a Zone.Identifier stream saying "Internet",
    /// so SmartScreen and Office check the file before anything in it runs.
    public func markDownloaded(_ url: URL) -> Bool {
        #if os(Windows)
        let mark = Array("[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=about:internet\r\n".utf8)
        return (url.path + ":Zone.Identifier").withCString(encodedAs: UTF16.self) { path in
            let file = CreateFileW(path, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            guard file != INVALID_HANDLE_VALUE else { return false }
            defer { CloseHandle(file) }
            var written: DWORD = 0
            return WriteFile(file, mark, DWORD(mark.count), &written, nil) && written == DWORD(mark.count)
        }
        #else
        return false
        #endif
    }
    public var preferredCodec: DisplayWire.Codec { .h264 }
    public func makeVideoDecoder(codec: DisplayWire.Codec) -> any VideoDecoding {
        guard let videoDecoder else { fatalError("no video in the console") }
        return videoDecoder(codec)
    }
    public func makeAudioOutput() -> any AudioOutput { NoSound() }
    public func makeMicrophone() -> any Microphone { NoMicrophone() }
    public func microphoneAllowed() async -> Bool { false }
}

/// Polls the clipboard's sequence number (as the Mac polls its change count).
@MainActor final class WindowsClipboard: Clipboard {
    private let onCopy: @MainActor (String) -> Void
    private var last: UInt32 = 0
    init(onCopy: @escaping @MainActor (String) -> Void) { self.onCopy = onCopy }

    func start() {
        #if os(Windows)
        last = GetClipboardSequenceNumber()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { self.poll() }
        }
        #endif
    }

    func write(_ text: String) {
        #if os(Windows)
        guard OpenClipboard(nil) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        let units = Array(text.utf16) + [0]
        guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(units.count * 2)), let p = GlobalLock(memory) else { return }
        units.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        GlobalUnlock(memory)
        SetClipboardData(UINT(CF_UNICODETEXT), memory)
        last = GetClipboardSequenceNumber()
        #endif
    }

    private func poll() {
        #if os(Windows)
        let now = GetClipboardSequenceNumber()
        guard now != last else { return }
        last = now
        guard OpenClipboard(nil) else { return }
        defer { CloseClipboard() }
        guard !Self.isPrivate() else { return } // a password manager's copy: not sent (as the Mac skips concealed ones)
        guard let handle = GetClipboardData(UINT(CF_UNICODETEXT)), let p = GlobalLock(handle) else { return }
        defer { GlobalUnlock(handle) }
        let text = String(decodingCString: p.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
        if !text.isEmpty { onCopy(text) }
        #endif
    }
}

#if os(Windows)
extension WindowsClipboard {
    /// The formats apps add to keep a copy out of clipboard monitors, history and the cloud.
    /// Call with the clipboard open.
    static func isPrivate() -> Bool {
        // Fails closed: anything that can't be checked counts as private.
        func format(_ name: String) -> UINT { name.withCString(encodedAs: UTF16.self) { RegisterClipboardFormatW($0) } }
        let exclude = format("ExcludeClipboardContentFromMonitorProcessing"), ignore = format("Clipboard Viewer Ignore")
        guard exclude != 0, ignore != 0 else { return true }
        if IsClipboardFormatAvailable(exclude) || IsClipboardFormatAvailable(ignore) { return true }
        // These two carry a DWORD: 0 means "not in history" / "not to the cloud".
        for name in ["CanIncludeInClipboardHistory", "CanUploadToCloudClipboard"] {
            let f = format(name)
            guard f != 0 else { return true }
            guard IsClipboardFormatAvailable(f) else { continue }
            guard let handle = GetClipboardData(f), GlobalSize(handle) >= 4, let p = GlobalLock(handle) else { return true }
            let allowed = p.load(as: DWORD.self)
            GlobalUnlock(handle)
            if allowed == 0 { return true }
        }
        return false
    }
}
#endif

@MainActor final class PrintedNotifications: SystemNotifications {
    var onDismiss: ((String) -> Void)?
    var onOpen: ((String) -> Void)?
    var onAction: ((String, Int, String?) -> Void)?
    var onOpenOnMac: ((String, String, String) -> Void)?
    func activate() {}
    func show(key: String, package: String, app: String, title: String, text: String,
              iconPNG: Data?, actions: [PhoneNotification.Action], quiet: Bool) {
        print("notification from \(app)\(quiet ? " (quiet)" : "")") // contents not printed: they're personal
    }
    func showLocal(id: String, title: String, body: String) { print("local notification: \(title)") }
    func remove(key: String) {}
    func reconcile() {}
    func keepOnly(_ keys: Set<String>) {}
    func removeAll() {}
}

@MainActor final class NoScreenshots: ScreenshotWatcher {
    var onNew: ((URL) -> Void)?
    var isOn = false
}


/// Sound isn't part of these tests: dropped.
final class NoSound: AudioOutput, @unchecked Sendable {
    func configure(sampleRate: Int, channels: Int) {}
    func play(_ packet: Data, ptsMicros: Int64, receivedMicros: Int64) {}
    func silence() {}
    var stats: (packets: Int, underruns: Int, dropped: Int, buffered: Int) { (0, 0, 0, 0) }
    func stop() {}
}

/// No microphone here: apps on the phone record from the phone's.
final class NoMicrophone: Microphone, @unchecked Sendable {
    var onChunk: (Data) -> Void = { _ in }
    func want(_ on: Bool) {}
    func start() -> Bool { false }
    func stop() {}
}
