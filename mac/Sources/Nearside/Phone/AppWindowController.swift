import NearsideCore
import AppKit
import Carbon
import SwiftUI

/// One phone app in a native Mac window. Resizing the window resizes the app's display on the
/// phone, so the app lays itself out again (as a Mac app would) instead of being scaled.
@MainActor
final class AppWindowController: NSObject, NSWindowDelegate {
    let app: PhoneApp
    let window: NSWindow
    private var session: PhoneAppSession! // made once the toolbar is in, so the size is final
    private let stream: StreamView
    private let overlay = OverlayHostingView(rootView: AppWindowOverlay(state: .opening, label: ""))
    private var state: PhoneAppSession.State = .opening
    private var resizeWork: DispatchWorkItem?
    private let onClosed: (AppWindowController) -> Void

    /// 75 % of the screen's height (at most 900 pt), a little wider than a phone, unless this app has
    /// a saved size.
    init?(app: PhoneApp, engine: SyncEngine, renderer: MetalRenderer, onClosed: @escaping (AppWindowController) -> Void) {
        self.app = app
        self.onClosed = onClosed
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Taller than wide, like the app expects, but roomier than a phone (9:20 felt cramped);
        // resize freely, the app relays itself out, and each app remembers its size.
        let height = min(screen.height * 0.75, 900).rounded()
        let content = NSRect(x: 0, y: 0, width: (height * 0.62).rounded(), height: height)
        window = NSWindow(contentRect: content, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = app.label
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 280, height: 360)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setFrameAutosaveName("PhoneApp-\(app.package)")
        if !window.setFrameUsingName("PhoneApp-\(app.package)") { window.center() }

        stream = StreamView(renderer: renderer)
        let container = NSView()
        container.addSubview(stream)
        container.addSubview(overlay)
        for view in [stream, overlay] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        window.contentView = container

        super.init()
        installToolbar()
        window.delegate = self
        let size = PhoneDisplaySize.forWindow(window.contentLayoutRect.size, scale: window.backingScaleFactor)
        session = engine.makePhoneAppSession(app, width: size.width, height: size.height, dpi: size.dpi)
        render(.opening)

        session.onFrame = { [renderer] frame in renderer.show(frame) }
        session.onState = { [weak self] state in self?.render(state) }
        session.onVideoSize = { [weak self] size in self?.stream.videoSize = size }
        stream.session = session
        window.initialFirstResponder = stream
        session.setKeyboardLayout(Self.keyboardLayout())
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardLayoutChanged),
                                               name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
        session.start()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: - States

    private func render(_ new: PhoneAppSession.State) {
        Trace.log("window shows \(new)")
        if new == .showing, state != .showing { testInputIfAsked() }
        state = new
        overlay.rootView = AppWindowOverlay(state: new, label: app.label, reopen: { [weak self] in self?.reopen() },
                                            close: { [weak self] in self?.window.close() })
        overlay.isHidden = new == .showing
    }

    /// Test hook: NEARSIDE_TEST_INPUT=1 taps the middle, then drags up, through the same path
    /// as the mouse (StreamView → session), so input can be checked without a person. `scroll` and
    /// `pinch` drive the trackpad paths the same way.
    private func testInputIfAsked() {
        guard let mode = ProcessInfo.processInfo.environment["NEARSIDE_TEST_INPUT"] else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            let size = stream.videoPointSize
            let now = { ProcessInfo.processInfo.systemUptime }
            if mode == "scroll" {
                // A two-finger flick up (content moves up), as a trackpad sends it, ~120 Hz.
                let at = CGPoint(x: size.width / 2, y: size.height * 0.7)
                stream.scrollDrag(.began, at: at, delta: CGVector(dx: 0, dy: -4), time: now())
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(8))
                    stream.scrollDrag(.changed, at: at, delta: CGVector(dx: 0, dy: -18), time: now())
                }
                stream.scrollDrag(.ended, at: at, delta: .zero, time: now())
                Trace.log("test scroll sent")
                return
            }
            if mode == "wheel" {
                for _ in 0..<5 {
                    stream.wheel(at: CGPoint(x: size.width / 2, y: size.height / 2), h: 0, v: -1)
                    try? await Task.sleep(for: .milliseconds(60))
                }
                Trace.log("test wheel sent")
                return
            }
            if mode == "mouse" {
                // Hover across, right-click, then a normal tap (the finger must still work after).
                for i in 0..<10 {
                    session.mouse(.hover, x: 0.2 + Float(i) * 0.05, y: 0.5)
                    try? await Task.sleep(for: .milliseconds(16))
                }
                session.mouse(.secondaryDown, x: 0.5, y: 0.5)
                try? await Task.sleep(for: .milliseconds(80))
                session.mouse(.secondaryUp, x: 0.5, y: 0.5)
                session.mouse(.hover, x: 0.5, y: 0.5)
                try? await Task.sleep(for: .seconds(1))
                stream.button(.down, at: CGPoint(x: size.width / 2, y: size.height * 0.6), time: now())
                stream.button(.up, at: CGPoint(x: size.width / 2, y: size.height * 0.6), time: now())
                Trace.log("test mouse sent")
                return
            }
            if mode == "pinch" {
                let at = CGPoint(x: size.width / 2, y: size.height / 2)
                stream.pinch(.began, at: at, by: 0, time: now())
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(16))
                    stream.pinch(.changed, at: at, by: 0.06, time: now())
                }
                stream.pinch(.ended, at: at, by: 0, time: now())
                Trace.log("test pinch sent")
                return
            }
            let touch = { [stream] (action: DisplayWire.TouchAction, x: CGFloat, y: CGFloat) in
                stream.button(action, at: CGPoint(x: x * size.width, y: y * size.height), time: now())
            }
            if mode == "keys" {
                // Real key events through the app, as the keyboard sends them: "ab", ⌘A, ⌫ (empties
                // the field), "ok cool", ⌥⌫ (deletes the word) → "ok ".
                @MainActor func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) async {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: now(),
                                                    windowNumber: window.windowNumber, context: nil, characters: chars,
                                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                            // ⌘ keys go to the key window's views first; launched from a shell the
                            // window can't become key, so hand them over as AppKit would.
                            if type == .keyDown, flags.contains(.command), window.performKeyEquivalent(with: e) { continue }
                            NSApp.sendEvent(e)
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(120))
                }
                window.makeFirstResponder(stream)
                await key(0x00, "a"); await key(0x0B, "b")
                await key(0x00, "a", .command); await key(0x33, "\u{7f}")
                for (code, c) in [(0x1F, "o"), (0x28, "k"), (0x31, " "), (0x08, "c"), (0x1F, "o"), (0x1F, "o"), (0x25, "l")] {
                    await key(UInt16(code), c)
                }
                await key(0x33, "\u{7f}", .option)
                Trace.log("test keys sent")
                return
            }
            if mode == "type" {
                // Tap the search field (Settings), then type: plain, Danish letters, dead-key
                // letters, AltGr symbols, an emoji (pasted), then ⌫ and Return.
                touch(.down, 0.5, 0.065); touch(.up, 0.5, 0.065)
                try? await Task.sleep(for: .seconds(2))
                let text = ProcessInfo.processInfo.environment["NEARSIDE_TEST_TEXT"] ?? "Hej æøå é ü @{}[] € ~ 🙂!"
                for c in text { // one at a time, as typed
                    stream.typeForTesting(String(c))
                    try? await Task.sleep(for: .milliseconds(300))
                }
                Trace.log("test type sent")
                return
            }
            if mode == "resize" {
                var frame = window.frame
                frame.size.width = (frame.size.height * 0.9).rounded()
                window.setFrame(frame, display: true) // not a live resize, like zoom or tiling
                try? await Task.sleep(for: .seconds(3))
                goBack() // then Back on the app's first screen
                return
            }
            if mode == "click" {
                // Real AppKit mouse events through the window, like a person's click.
                let point = stream.convert(NSPoint(x: stream.bounds.midX, y: stream.bounds.height * 0.25), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                      clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                        window.sendEvent(event)
                    }
                    try? await Task.sleep(for: .milliseconds(90))
                }
                Trace.log("test click sent; overlay hidden \(overlay.isHidden), state \(state), hit view: \(String(describing: window.contentView?.hitTest(point)))")
                return
            }
            touch(.down, 0.5, 0.75); try? await Task.sleep(for: .milliseconds(80)); touch(.up, 0.5, 0.75)
            NSLog("Nearside: test tap sent")
            if mode == "tap" { return }
            try? await Task.sleep(for: .seconds(1))
            touch(.down, 0.5, 0.8)
            for i in 1...20 {
                try? await Task.sleep(for: .milliseconds(16))
                touch(.move, 0.5, 0.8 - CGFloat(i) * 0.025)
            }
            touch(.up, 0.5, 0.3)
            NSLog("Nearside: test input sent")
        }
    }

    private func reopen() {
        // The app was closed or moved to the phone: a fresh window brings it back.
        window.close()
        PhoneWindowManager.shared?.open(app)
    }

    // MARK: - Toolbar

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "PhoneAppToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
    }

    @objc private func goBack() { session.back() }

    // MARK: - Window events

    func windowDidResize(_ notification: Notification) {
        // Zoom, tiling, full screen: no live resize, so react here (a drag waits for its end).
        if !window.inLiveResize { scheduleResize() }
    }

    func windowDidEndLiveResize(_ notification: Notification) { scheduleResize() }

    /// Let the hand settle, then give the phone the window's new size.
    private func scheduleResize() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let size = PhoneDisplaySize.forWindow(window.contentLayoutRect.size, scale: window.backingScaleFactor)
            session.resize(width: size.width, height: size.height, dpi: size.dpi)
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        scheduleResize() // moved to a screen with a different scale
    }

    func windowDidResignKey(_ notification: Notification) { stream.cancelInput() }

    @objc private func keyboardLayoutChanged() { session.setKeyboardLayout(Self.keyboardLayout()) }

    /// The Mac's keyboard layout as "name\nlanguage" ("Danish\nda", "US\nen"): the phone picks the
    /// Android layout that can type the same characters. The name is from the input source id, so
    /// it's the same whatever language the Mac's menus are in.
    static func keyboardLayout() -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return "" }
        func property(_ key: CFString) -> AnyObject? {
            TISGetInputSourceProperty(source, key).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
        }
        let id = property(kTISPropertyInputSourceID) as? String ?? ""
        let language = (property(kTISPropertyInputSourceLanguages) as? [String])?.first ?? ""
        let name = id.components(separatedBy: ".").last ?? ""
        return "\(name)\n\(language)"
    }

    @objc private func occlusionChanged() {
        let visible = window.occlusionState.contains(.visible)
        NSLog("Nearside: phone app window \(app.package) \(visible ? "visible" : "hidden")")
        session.setVisible(visible)
    }

    func windowWillClose(_ notification: Notification) {
        session.close() // the app goes back to the phone, under what's showing there
        NotificationCenter.default.removeObserver(self)
        onClosed(self)
    }
}

extension AppWindowController: NSToolbarDelegate {
    private static let back = NSToolbarItem.Identifier("back")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.back] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.back] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Self.back else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Back"
        item.toolTip = "Back"
        item.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
        item.isBordered = true
        item.target = self
        item.action = #selector(goBack)
        return item
    }
}

/// SwiftUI's hosting view keeps claiming mouse hits while hidden, which sent clicks meant for the
/// app to the invisible overlay; hidden, it lets them through.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
}

/// What the window shows when it isn't showing the app.
struct AppWindowOverlay: View {
    let state: PhoneAppSession.State
    let label: String
    var reopen: () -> Void = {}
    var close: () -> Void = {}

    var body: some View {
        ZStack {
            Rectangle().fill(.background.opacity(state == .reconnecting ? 0.55 : 1))
                .background(.ultraThinMaterial)
            VStack(spacing: 14) {
                switch state {
                case .opening, .showing, .closed:
                    ProgressView().controlSize(.regular)
                    Text("Opening \(label)…").font(.headline)
                case .reconnecting:
                    ProgressView().controlSize(.regular)
                    Text("Reconnecting…").font(.headline)
                    Text("\(label) stays open on your phone.").font(.subheadline).foregroundStyle(.secondary)
                case .gone(let reason):
                    Image(systemName: reason == .movedToPhone ? "iphone.and.arrow.forward" : "xmark.app")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                    Text(reason == .movedToPhone ? "\(label) moved to your phone" : "\(label) was closed")
                        .font(.headline)
                    HStack {
                        Button(reason == .movedToPhone ? "Bring Back" : "Reopen", action: reopen).keyboardShortcut(.defaultAction)
                        Button("Close Window", action: close)
                    }
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                    Text(message).font(.headline).multilineTextAlignment(.center)
                    HStack {
                        Button("Try Again", action: reopen).keyboardShortcut(.defaultAction)
                        Button("Close Window", action: close)
                    }
                }
            }
            .padding(24)
        }
    }
}
