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
    private let onClosed: (AppWindowController) -> Void
    /// The status bar's rows at the top of the display (the phone says; see PhoneDisplaySize).
    private var cropPixels = 0
    private var videoPixels: CGSize?
    /// Covered after the Mac slept or locked, until Touch ID (AuthGate).
    private var locked = false
    /// The vertical toolbar beside the app: Back, then the toolbox.
    private var tools: SideToolbar!
    /// The app's window blocks capture (FLAG_SECURE): the picture is black, so say why.
    private var secure = false

    // MARK: Size (the toolbox): a preset, never a free resize

    /// Phone / Foldable / Tablet, remembered per app.
    private var size: PhoneSize {
        get { PhoneSize(rawValue: UserDefaults.standard.string(forKey: "PhoneApp.size.\(app.package)") ?? "") ?? .phone }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "PhoneApp.size.\(app.package)") }
    }

    private var dp: CGSize { size.dp(phone: PhoneInfo.screenDp) }
    /// What the window shows: all but the status bar the phone gives the display.
    private var shownDp: CGSize { PhoneDisplaySize.shownDp(dp, statusBarDp: PhoneInfo.statusBarDp) }

    /// The display keeps the preset's dp at the phone's density; the window only scales it.
    private func displaySize() -> (width: Int, height: Int, dpi: Int) {
        PhoneDisplaySize.forPreset(dp, density: PhoneInfo.densityDpi)
    }

    /// Window points per dp: saved per app and size, else what fits the screen.
    private var zoom: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "PhoneApp.zoom.\(app.package).\(size.rawValue)")
        if saved > 0 { return saved }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 875)
        return PhoneSize.fittingZoom(shownDp, chrome: CGSize(width: SideToolbar.width, height: window.frame.height - window.contentLayoutRect.height),
                                     screen: screen)
    }

    /// The window to the size's shape at `zoom`, its top-left corner kept.
    private func fitWindow(zoom z: CGFloat, animate: Bool) {
        let content = NSSize(width: (shownDp.width * z).rounded() + SideToolbar.width, height: (shownDp.height * z).rounded())
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame { // stay on screen
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        // Animated through Core Animation: setFrame(animate: true) runs a nested event loop,
        // and run from a Swift Task that crashed the app (a timer's MainActor check inside it).
        if animate {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; window.animator().setFrame(frame, display: true) }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    init?(app: PhoneApp, engine: SyncEngine, renderer: MetalRenderer, icon: NSImage?,
          onClosed: @escaping (AppWindowController) -> Void) {
        self.app = app
        self.onClosed = onClosed
        // A preset size (the toolbox), not resizable: the app lays out once per size.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 800), styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = app.label
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("PhoneApp-\(app.package)") // where it was; its size comes from the preset
        let placed = window.setFrameUsingName("PhoneApp-\(app.package)")
        if let icon {
            // The app's icon in the title bar (as a document's) and on the minimised window.
            window.representedURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(app.label)
            window.standardWindowButton(.documentIconButton)?.image = icon
            window.miniwindowImage = icon
        }

        stream = StreamView(renderer: renderer)
        let container = NSView()
        container.addSubview(stream)
        container.addSubview(overlay)
        window.contentView = container

        super.init()
        // The app on the left, the toolbar on the right: nothing covers the app.
        tools = SideToolbar([
            .button(id: "back", symbol: "chevron.backward", label: "Back (⌘[)") { [weak self] in self?.goBack(nil) },
            .separator,
            .button(id: PhoneSize.phone.rawValue, symbol: PhoneSize.phone.symbol, label: "Phone size (⌃⌘1)") { [weak self] in self?.setSize(.phone) },
            .button(id: PhoneSize.foldable.rawValue, symbol: PhoneSize.foldable.symbol, label: "Foldable size (⌃⌘2)") { [weak self] in self?.setSize(.foldable) },
            .button(id: PhoneSize.tablet.rawValue, symbol: PhoneSize.tablet.symbol, label: "Tablet size (⌃⌘3)") { [weak self] in self?.setSize(.tablet) },
            .spacer,
            .button(id: "toPhone", symbol: "iphone.and.arrow.forward", label: "Open on Phone") { [weak self] in self?.openOnPhone() },
        ])
        container.addSubview(tools)
        for view in [stream, overlay, tools] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            stream.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stream.trailingAnchor.constraint(equalTo: tools.leadingAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: tools.leadingAnchor),
            tools.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        updateToolbox()
        fitWindow(zoom: zoom, animate: false)
        if !placed { window.center() }
        stream.macShortcuts = ["=", "+", "-", "0"] // View → Larger / Smaller / Actual Size
        window.delegate = self
        let size = displaySize()
        session = engine.makePhoneAppSession(app, width: size.width, height: size.height, dpi: size.dpi)
        render(.opening)

        session.onFrame = { [renderer] frame in renderer.show(frame) }
        session.onState = { [weak self] state in self?.render(state) }
        session.onThermal = { [weak self] reduced in
            NSLog("Nearside: phone \(reduced ? "warm: quality reduced" : "cool again")")
            self?.window.subtitle = reduced ? "Lower quality: your phone is warm" : ""
        }
        session.onSecure = { [weak self] on in
            guard let self else { return }
            secure = on
            render(state)
        }
        session.onVideoSize = { [weak self] size in
            guard let self else { return }
            videoPixels = size
            showVideoSize()
        }
        session.onCrop = { [weak self] rows in
            guard let self else { return }
            cropPixels = rows
            renderer.cropPixels = rows
            showVideoSize()
        }
        stream.session = session
        window.initialFirstResponder = stream
        session.setKeyboardLayout(Self.keyboardLayout())
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardLayoutChanged),
                                               name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateVisibility), name: name, object: nil)
        }
        session.start()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        PhoneWindowManager.bringToFront()
    }

    // MARK: - States

    private func render(_ new: PhoneAppSession.State) {
        Trace.log("window shows \(new)")
        if new == .showing, state != .showing { testInputIfAsked() }
        state = new
        overlay.rootView = AppWindowOverlay(state: new, label: app.label, locked: locked, secure: secure,
                                            reopen: { [weak self] in self?.reopen() },
                                            close: { [weak self] in self?.window.close() },
                                            unlock: { PhoneWindowManager.shared?.unlock() },
                                            openOnPhone: { [weak self] in self?.openOnPhone() },
                                            oldest: new == .busy ? PhoneWindowManager.shared?.leastRecentlyUsed(except: self)?.app.label : nil,
                                            closeOldest: { [weak self] in self?.closeOldestAndRetry() })
        overlay.isHidden = new == .showing && !locked && !secure
        // Test hook: NEARSIDE_TEST_OVERLAY=<png> saves what the window shows over the app.
        if let path = ProcessInfo.processInfo.environment["NEARSIDE_TEST_OVERLAY"], !overlay.isHidden {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [overlay] in
                guard let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { return }
                overlay.cacheDisplay(in: overlay.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// Covers the app (and stops its video) while the Mac is locked to phone apps.
    func setLocked(_ locked: Bool) {
        guard locked != self.locked else { return }
        self.locked = locked
        if locked { stream.cancelInput() }
        stream.session = locked ? nil : session // no keys reach the app either
        updateVisibility()
        render(state)
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
            if mode == "keys" || mode == "copy" || mode == "paste" {
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
                if mode == "copy" { await key(0x00, "a", .command); await key(0x08, "c", .command) }
                if mode == "paste" {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(" fra Mac 🙂", forType: .string)
                    await key(0x09, "v", .command)
                }
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
            if mode == "size", let spec = ProcessInfo.processInfo.environment["NEARSIDE_TEST_SIZE"],
               let first = PhoneSize(rawValue: spec) {
                // Size names: switch, optionally to a second (NEARSIDE_TEST_SIZE2) 8 s later, then
                // close (NEARSIDE_TEST_CLOSE_AFTER): the app goes back to the phone.
                setSize(first)
                try? await Task.sleep(for: .seconds(8))
                if let second = ProcessInfo.processInfo.environment["NEARSIDE_TEST_SIZE2"].flatMap(PhoneSize.init(rawValue:)) {
                    setSize(second)
                    try? await Task.sleep(for: .seconds(8))
                }
                NSLog("Nearside: test sizes: picture \(stream.bounds.size), video \(stream.videoPointSize), size \(self.size.rawValue)")
                if let path = ProcessInfo.processInfo.environment["NEARSIDE_TEST_OVERLAY"], let view = window.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                if let wait = Double(ProcessInfo.processInfo.environment["NEARSIDE_TEST_CLOSE_AFTER"] ?? "") {
                    try? await Task.sleep(for: .seconds(wait))
                    window.close()
                }
                return
            }
            if mode == "size", let spec = ProcessInfo.processInfo.environment["NEARSIDE_TEST_SIZE"] {
                // "WxH" in points: the window's content size (e.g. phone-shaped "400x880").
                let parts = spec.split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { window.setContentSize(NSSize(width: parts[0], height: parts[1])) }
                Trace.log("test size \(spec)")
                // NEARSIDE_TEST_SIZE2: a second size a while later (e.g. big, then phone-sized).
                if let spec2 = ProcessInfo.processInfo.environment["NEARSIDE_TEST_SIZE2"] {
                    try? await Task.sleep(for: .seconds(8))
                    let p2 = spec2.split(separator: "x").compactMap { Double($0) }
                    if p2.count == 2 { window.setContentSize(NSSize(width: p2[0], height: p2[1])) }
                    Trace.log("test size \(spec2)")
                }
                // NEARSIDE_TEST_CLOSE_AFTER: then close (the app goes back to the phone at that size's config).
                if let wait = Double(ProcessInfo.processInfo.environment["NEARSIDE_TEST_CLOSE_AFTER"] ?? "") {
                    try? await Task.sleep(for: .seconds(wait))
                    window.close()
                }
                return
            }
            if mode == "hide" {
                // Minimise for NEARSIDE_TEST_CLOSE_AFTER seconds (default 20), then restore.
                let wait = Double(ProcessInfo.processInfo.environment["NEARSIDE_TEST_CLOSE_AFTER"] ?? "") ?? 20
                window.miniaturize(nil)
                try? await Task.sleep(for: .seconds(wait))
                window.deminiaturize(nil)
                Trace.log("test restored")
                return
            }
            if mode == "close" {
                let wait = Double(ProcessInfo.processInfo.environment["NEARSIDE_TEST_CLOSE_AFTER"] ?? "") ?? 0
                try? await Task.sleep(for: .seconds(wait))
                window.close() // as ⌘W: the app goes back to the phone (paused if it was playing)
                return
            }
            if mode == "resize" {
                var frame = window.frame
                frame.size.width = (frame.size.height * 0.9).rounded()
                window.setFrame(frame, display: true) // not a live resize, like zoom or tiling
                try? await Task.sleep(for: .seconds(3))
                goBack(nil) // then Back on the app's first screen
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
            // NEARSIDE_TEST_TAP="x,y" (0…1 of what the window shows) picks the spot.
            let at = (ProcessInfo.processInfo.environment["NEARSIDE_TEST_TAP"] ?? "0.5,0.75").split(separator: ",").compactMap { Double($0) }
            let (tx, ty) = at.count == 2 ? (CGFloat(at[0]), CGFloat(at[1])) : (0.5, 0.75)
            touch(.down, tx, ty); try? await Task.sleep(for: .milliseconds(80)); touch(.up, tx, ty)
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


    @objc func goBack(_ sender: Any?) { if !locked { session.back() } }

    /// Busy: closes the least recently used other window, then opens this app again.
    private func closeOldestAndRetry() {
        guard let oldest = PhoneWindowManager.shared?.leastRecentlyUsed(except: self) else { return }
        oldest.window.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.reopen() } // its encoder is freed
    }

    /// The app, in front on the phone; the window closes.
    fileprivate func openOnPhone() {
        session.openOnPhone()
        window.close()
    }

    /// Dock menu: this window to the front.
    @objc func bringForward(_ sender: Any?) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        show()
    }

    /// What's shown of the video: all but the status bar's rows.
    private func showVideoSize() {
        guard let videoPixels else { return }
        stream.videoSize = CGSize(width: videoPixels.width, height: videoPixels.height - CGFloat(cropPixels))
    }

    /// Toolbox / View → Phone, Foldable, Tablet.
    @objc func sizePhone(_ sender: Any?) { setSize(.phone) }
    @objc func sizeFoldable(_ sender: Any?) { setSize(.foldable) }
    @objc func sizeTablet(_ sender: Any?) { setSize(.tablet) }

    fileprivate func setSize(_ new: PhoneSize) {
        guard new != size, !locked else { return updateToolbox() }
        size = new
        applySize()
        fitWindow(zoom: zoom, animate: true)
        updateToolbox()
    }

    // View → Larger / Smaller / Actual Size: the picture only (the app keeps its layout).
    private static let zooms: [CGFloat] = [0.4, 0.5, 0.6, 0.7, 0.75, 0.8, 0.9, 1.0, 1.15, 1.3, 1.5]
    @objc func zoomIn(_ sender: Any?) { setZoom(Self.zooms.first { $0 > zoom + 0.01 } ?? Self.zooms.last!) }
    @objc func zoomOut(_ sender: Any?) { setZoom(Self.zooms.last { $0 < zoom - 0.01 } ?? Self.zooms.first!) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ z: CGFloat) {
        UserDefaults.standard.set(Double(z), forKey: "PhoneApp.zoom.\(app.package).\(size.rawValue)")
        fitWindow(zoom: z, animate: true)
    }

    // MARK: - Window events

    private func applySize() {
        let size = displaySize()
        session.resize(width: size.width, height: size.height, dpi: size.dpi)
    }

    func windowDidResignKey(_ notification: Notification) {
        stream.cancelInput()
        updateVisibility()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        PhoneWindowManager.shared?.focused(self)
        updateVisibility()
    }

    private var lastVisibility: PhoneAppSession.Visibility?

    /// The window in use (key, Nearside active) gets the phone's full frame rate; others on
    /// screen less; hidden (covered, minimised, another Space, locked) none.
    @objc private func updateVisibility() {
        let visibility: PhoneAppSession.Visibility =
            locked || !window.occlusionState.contains(.visible) ? .hidden
            : window.isKeyWindow && NSApp.isActive ? .focused : .visible
        guard visibility != lastVisibility else { return }
        lastVisibility = visibility
        NSLog("Nearside: phone app window \(app.package) \(visibility)")
        session.setVisibility(visibility)
    }

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

    @objc private func occlusionChanged() { updateVisibility() }

    // The title-bar icon is only an icon: no path menu, no dragging a file.
    func window(_ window: NSWindow, shouldPopUpDocumentPathMenu menu: NSMenu) -> Bool { false }
    func window(_ window: NSWindow, shouldDragDocumentWith event: NSEvent, from dragImageLocation: NSPoint,
                with pasteboard: NSPasteboard) -> Bool { false }

    func windowWillClose(_ notification: Notification) {
        session.close() // the app goes back to the phone, under what's showing there
        NotificationCenter.default.removeObserver(self)
        onClosed(self)
    }
}

extension AppWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(goBack(_:)) { return !locked && state == .showing }
        return true
    }
}

extension AppWindowController {
    /// The toolbox shows the current size.
    func updateToolbox() {
        guard let tools else { return }
        for size in PhoneSize.allCases { tools.setSelected(size.rawValue, size == self.size) }
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
    var locked = false
    var secure = false
    var reopen: () -> Void = {}
    var close: () -> Void = {}
    var unlock: () -> Void = {}
    var openOnPhone: () -> Void = {}
    /// Busy: the least recently used other window's app, and closing it (then this one opens).
    var oldest: String? = nil
    var closeOldest: () -> Void = {}

    var body: some View {
        ZStack {
            Rectangle().fill(.background.opacity(state == .reconnecting && !locked ? 0.55 : 1))
                .background(.ultraThinMaterial)
            VStack(spacing: 14) {
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text("\(label) is locked").font(.headline)
                    Text("Your Mac was locked. Unlock to keep using your phone's apps.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Unlock", action: unlock).keyboardShortcut(.defaultAction)
                } else if secure, state == .showing {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text("\(label) blocks screen sharing").font(.headline)
                    Text("It hides its screen from recordings and other displays, so it can only be used on your phone.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                    HStack {
                        Button("Open on Phone", action: openOnPhone).keyboardShortcut(.defaultAction)
                        Button("Close Window", action: close)
                    }
                } else {
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
                case .busy:
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                    Text("Your phone can't show more apps at once").font(.headline).multilineTextAlignment(.center)
                    if let oldest {
                        Text("Close \(oldest), the app you used longest ago, to open \(label).")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    HStack {
                        if let oldest { Button("Close \(oldest)", action: closeOldest).keyboardShortcut(.defaultAction) }
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
            }
            .padding(24)
        }
    }
}
