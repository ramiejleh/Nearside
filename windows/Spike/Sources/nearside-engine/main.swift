import Foundation
import NearsideCore
#if os(Windows)
import WinSDK
#endif

// The engine in a console, for Phase 3: the same SyncEngine as the Mac app, with a minimal
// platform (the Windows clipboard; the rest does nothing yet).
//   nearside-engine pair <ip:port> <code> [apk]   set up: pair, install the phone app, start the helper
//   nearside-engine                               run: connect, sync the clipboard, print what happens

final class ConsolePlatform: Platform, @unchecked Sendable {
    var computerName: String { ProcessInfo.processInfo.hostName }
    var osName: String? { "windows" }
    var bundledPhoneAppVersion: Int? { nil } // don't update the phone app from here
    @MainActor func makeClipboard(onCopy: @escaping @MainActor (String) -> Void) -> any Clipboard { WindowsClipboard(onCopy: onCopy) }
    @MainActor func makeNotifications() -> any SystemNotifications { PrintedNotifications() }
    @MainActor func makeScreenshotWatcher() -> any ScreenshotWatcher { NoScreenshots() }
    @MainActor func watchReachability(_ changed: @escaping @MainActor () -> Void) {}
    @MainActor func reveal(_ url: URL) {}
    /// Mark of the Web, as a browser download gets: a Zone.Identifier stream saying "Internet",
    /// so SmartScreen and Office check the file before anything in it runs.
    func markDownloaded(_ url: URL) -> Bool {
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
    var preferredCodec: DisplayWire.Codec { .h264 }
    func makeVideoDecoder(codec: DisplayWire.Codec) -> any VideoDecoding { fatalError("no video in the console") }
    func makeAudioOutput() -> any AudioOutput { fatalError("no sound in the console") }
    func makeMicrophone() -> any Microphone { fatalError("no microphone in the console") }
    func microphoneAllowed() async -> Bool { false }
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
        func format(_ name: String) -> UINT { name.withCString(encodedAs: UTF16.self) { RegisterClipboardFormatW($0) } }
        if IsClipboardFormatAvailable(format("ExcludeClipboardContentFromMonitorProcessing")) ||
            IsClipboardFormatAvailable(format("Clipboard Viewer Ignore")) { return true }
        // These two carry a DWORD: 0 means "not in history" / "not to the cloud".
        for name in ["CanIncludeInClipboardHistory", "CanUploadToCloudClipboard"] {
            let f = format(name)
            guard IsClipboardFormatAvailable(f), let handle = GetClipboardData(f), let p = GlobalLock(handle) else { continue }
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

Platforms.current = ConsolePlatform()
setvbuf(stdout, nil, _IONBF, 0) // unbuffered: Windows rejects line buffering with no size
let args = CommandLine.arguments.dropFirst().map { $0 }

MainActor.assumeIsolated {
    let apk = args.count >= 4 ? URL(fileURLWithPath: args[3]) : nil
    let engine = SyncEngine(apkURL: apk)
    engine.onArrival = { item in print("clip from the phone: \(item.text.count) characters") }
    engine.start()
    if args.first == "pair", args.count >= 3 { engine.pair(hostPort: args[1], code: args[2]) }
    var lastState = "", lastSteps = ""
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        MainActor.assumeIsolated {
            let state = "\(engine.state)\(engine.appLinked ? ", phone app linked" : "")"
            if state != lastState { lastState = state; print("state: \(state) (\(engine.phoneName))") }
            let steps = engine.setupSteps.map { "\($0.title): \($0.status)" }.joined(separator: "\n  ")
            if steps != lastSteps { lastSteps = steps; if !steps.isEmpty { print("setup:\n  \(steps)") } }
        }
    }
}
RunLoop.main.run()
