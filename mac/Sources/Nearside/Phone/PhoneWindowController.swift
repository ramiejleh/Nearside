import NearsideCore
import AppKit
import SwiftUI

/// The phone window: a whole phone of its own on the Mac, separate from the real phone's screen.
/// Our home screen runs on its display, and apps opened there stay there. It looks like a phone:
/// borderless and rounded, with the vertical toolbar beside the screen (never over it): close,
/// minimise, Back / Home / Recents, and the toolbox's sizes (Phone / Foldable / Tablet). The
/// display is the size's dp at the phone's density; Larger / Smaller only scale the picture.
@MainActor
final class PhoneWindowController: NSObject, NSWindowDelegate {
    let window: PhoneWindow
    private let session: PhoneAppSession
    private let stream: StreamView
    private let overlay = OverlayHostingView(rootView: AppWindowOverlay(state: .opening, label: "Phone"))
    /// Pass-through while hidden: a hidden SwiftUI hosting view still claims mouse hits, and the
    /// hidden Recents swallowed the phone window's clicks and drags (user report).
    private let recents: OverlayHostingView<RecentsView>
    private let recentsModel = RecentsModel()
    private var tools: SideToolbar!
    private let library: PhoneAppLibrary
    private let onClosed: (PhoneWindowController) -> Void
    private var state: PhoneAppSession.State = .opening
    private var locked = false
    private var secure = false
    private static let zooms: [CGFloat] = [0.4, 0.5, 0.6, 0.7, 0.75, 0.8, 0.9, 1.0, 1.15, 1.3, 1.5]

    /// Phone / Foldable / Tablet (the toolbox), remembered.
    private var size: PhoneSize {
        get { PhoneSize(rawValue: UserDefaults.standard.string(forKey: "PhoneWindow.size") ?? "") ?? .phone }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "PhoneWindow.size") }
    }

    /// The screen in dp (points at actual size).
    private var dp: CGSize { size.dp(phone: PhoneInfo.screenDp) }
    /// What the window shows: all but the status bar the phone gives the display.
    private var shownDp: CGSize { PhoneDisplaySize.shownDp(dp, statusBarDp: PhoneInfo.statusBarDp) }
    /// The status bar's rows at the top of the display (the phone says), and the video's size.
    private var cropPixels = 0
    private var videoPixels: CGSize?

    init?(engine: SyncEngine, library: PhoneAppLibrary, renderer: MetalRenderer, onClosed: @escaping (PhoneWindowController) -> Void) {
        self.library = library
        self.onClosed = onClosed
        let size = PhoneSize(rawValue: UserDefaults.standard.string(forKey: "PhoneWindow.size") ?? "") ?? .phone
        // The display: the size's dp at 2 px per dp (crisp on Retina at actual size).
        let display = PhoneDisplaySize.forPreset(size.dp(phone: PhoneInfo.screenDp), density: PhoneInfo.densityDpi)
        session = engine.makePhoneWindowSession(width: display.width, height: display.height, dpi: display.dpi)

        window = PhoneWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 800),
                             styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Phone"
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.collectionBehavior.insert(.fullScreenNone)
        window.setFrameAutosaveName("PhoneWindow") // where it was; its size comes from the preset
        let placed = window.setFrameUsingName("PhoneWindow")

        stream = StreamView(renderer: renderer)
        stream.macShortcuts = ["1", "2", "=", "+", "-", "0", "w", "m"]
        recents = OverlayHostingView(rootView: RecentsView(model: recentsModel, library: library))
        recents.isHidden = true

        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        for view in [stream, overlay, recents] as [NSView] { container.addSubview(view) }
        window.contentView = container
        super.init()
        tools = SideToolbar([
            .button(id: "close", symbol: "xmark.circle.fill", label: "Close (⌘W)") { [weak self] in self?.window.performClose(nil) },
            .button(id: "minimize", symbol: "minus.circle.fill", label: "Minimise (⌘M)") { [weak self] in self?.window.miniaturize(nil) },
            .separator,
            .button(id: "back", symbol: "chevron.backward", label: "Back (⌘[)") { [weak self] in self?.goBack(nil) },
            .button(id: "home", symbol: "circle", label: "Home (⌘1)") { [weak self] in self?.goHome(nil) },
            .button(id: "recents", symbol: "square.on.square", label: "Recents (⌘2)") { [weak self] in self?.toggleRecents(nil) },
            .separator,
            .button(id: PhoneSize.phone.rawValue, symbol: PhoneSize.phone.symbol, label: "Phone size (⌃⌘1)") { [weak self] in self?.setSize(.phone) },
            .button(id: PhoneSize.foldable.rawValue, symbol: PhoneSize.foldable.symbol, label: "Foldable size (⌃⌘2)") { [weak self] in self?.setSize(.foldable) },
            .button(id: PhoneSize.tablet.rawValue, symbol: PhoneSize.tablet.symbol, label: "Tablet size (⌃⌘3)") { [weak self] in self?.setSize(.tablet) },
            .spacer,
            .button(id: "warm", symbol: "thermometer.medium", label: "Lower quality: your phone is warm") {},
        ])
        tools.dragsWindow = true
        tools.setHidden("warm", true)
        container.addSubview(tools)
        // The screen on the left, the toolbar on the right: nothing covers the app.
        for view in [stream, overlay, recents, tools] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            if view !== tools {
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
                view.trailingAnchor.constraint(equalTo: tools.leadingAnchor).isActive = true
            }
        }
        tools.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
        updateSizes()
        window.delegate = self
        fitWindow(zoom: zoom, animate: false)
        if !placed { window.center() }

        recentsModel.onPick = { [weak self] task in self?.pick(task) }
        recentsModel.onRemove = { [weak self] task in self?.session.remove(task: task.id) }
        recentsModel.onDismiss = { [weak self] in self?.hideRecents() }
        recentsModel.onHome = { [weak self] in self?.goHome(nil) }

        session.onFrame = { [renderer] frame in renderer.show(frame) }
        session.onState = { [weak self] state in self?.render(state) }
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
        session.onThermal = { [weak self] reduced in self?.tools.setHidden("warm", !reduced) }
        session.onSecure = { [weak self] on in
            guard let self else { return }
            secure = on
            render(state)
        }
        session.onTasks = { [weak self] tasks in self?.recentsModel.tasks = tasks }
        session.onSnapshot = { [weak self] task, jpeg in self?.recentsModel.snapshots[task] = NSImage(data: jpeg) }
        stream.session = session
        stream.onDropFiles = { [weak self, weak engine] urls in // to the app on top
            guard let self, let engine, !locked else { return }
            engine.shareFiles(urls, into: session)
        }
        window.initialFirstResponder = stream
        session.setKeyboardLayout(AppWindowController.keyboardLayout())
        session.setDock(dock())
        NotificationCenter.default.addObserver(self, selector: #selector(updateVisibility),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateVisibility), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardLayoutChanged),
                                               name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardLayoutChanged),
                                               name: PhoneWindowManager.keyboardLayoutSettingChanged, object: nil)
        render(.opening)
        session.start()
        testIfAsked()
    }

    /// Test hook: NEARSIDE_TEST_PHONE=recents opens Recents once showing and saves it to
    /// NEARSIDE_TEST_OVERLAY (png).
    private func testIfAsked() {
        let mode = ProcessInfo.processInfo.environment["NEARSIDE_TEST_PHONE"]
        guard mode == "recents" || mode == "close" || mode == "bar" || mode == "drag" else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["NEARSIDE_TEST_WAIT"] ?? "") ?? 12))
            guard let self else { return }
            if mode == "close" { return window.performClose(nil) }
            if mode == "drag" {
                // Real AppKit mouse events through the window: press, drag up 300 pt, release.
                let start = stream.convert(NSPoint(x: stream.bounds.midX, y: stream.bounds.height * 0.3), to: nil)
                func send(_ type: NSEvent.EventType, _ p: NSPoint) {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                  pressure: type == .leftMouseUp ? 0 : 1) { window.sendEvent(e) }
                }
                NSLog("Nearside: drag test: hit \(String(describing: window.contentView?.hitTest(window.contentView!.convert(start, from: nil)))), key \(window.isKeyWindow), first responder \(String(describing: window.firstResponder))")
                send(.leftMouseDown, start)
                for i in 1...30 {
                    try? await Task.sleep(for: .milliseconds(16))
                    send(.leftMouseDragged, NSPoint(x: start.x, y: start.y + CGFloat(i) * 10))
                }
                send(.leftMouseUp, NSPoint(x: start.x, y: start.y + 300))
                Trace.log("test drag sent")
                return
            }
            if mode == "bar" {
                if let new = ProcessInfo.processInfo.environment["NEARSIDE_TEST_SIZE"].flatMap(PhoneSize.init(rawValue:)) {
                    setSize(new)
                    try? await Task.sleep(for: .seconds(4))
                }
                guard let view = window.contentView, let path = ProcessInfo.processInfo.environment["NEARSIDE_TEST_OVERLAY"],
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                return
            }
            toggleRecents(nil)
            try? await Task.sleep(for: .seconds(6))
            NSLog("Nearside: recents: \(recentsModel.tasks?.map(\.package) ?? []), \(recentsModel.snapshots.count) pictures")
            guard let path = ProcessInfo.processInfo.environment["NEARSIDE_TEST_OVERLAY"],
                  let rep = recents.bitmapImageRepForCachingDisplay(in: recents.bounds) else { return }
            recents.cacheDisplay(in: recents.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    /// The Mac's favourite phone apps, then the most used, for the home screen's dock.
    private func dock() -> [String] {
        var packages = library.favouriteApps().map(\.package)
        for app in library.recents(8) where packages.count < 5 && !packages.contains(app.package) { packages.append(app.package) }
        return Array(packages.prefix(5))
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        PhoneWindowManager.bringToFront()
    }

    // MARK: - States

    private func render(_ new: PhoneAppSession.State) {
        state = new
        overlay.rootView = AppWindowOverlay(state: new, label: "Phone", locked: locked, secure: secure,
                                            reopen: { [weak self] in self?.reopen() },
                                            close: { [weak self] in self?.window.close() },
                                            unlock: { PhoneWindowManager.shared?.unlock() },
                                            openOnPhone: { [weak self] in self?.closeOnTop() })
        // The phone window has no single app that can leave: "gone" can't happen; a closed home
        // screen comes back by itself.
        overlay.isHidden = new == .showing && !locked && !secure
    }

    private func reopen() {
        window.close()
        PhoneWindowManager.shared?.openPhoneWindow()
    }

    private func closeOnTop() {
        session.openOnPhone()
        window.close()
    }

    func setLocked(_ locked: Bool) {
        guard locked != self.locked else { return }
        self.locked = locked
        if locked { stream.cancelInput(); hideRecents() }
        stream.session = locked ? nil : session
        updateVisibility()
        render(state)
    }

    // MARK: - Navigation (bar, View menu, ⌘[ ⌘1 ⌘2)

    @objc func goBack(_ sender: Any?) {
        guard !locked else { return }
        if !recents.isHidden { return hideRecents() }
        session.back()
    }

    @objc func goHome(_ sender: Any?) {
        guard !locked else { return }
        hideRecents()
        session.home()
    }

    @objc func toggleRecents(_ sender: Any?) {
        guard !locked else { return }
        if recents.isHidden { showRecents() } else { hideRecents() }
    }

    private func showRecents() {
        recentsModel.tasks = nil
        recentsModel.snapshots = [:]
        session.requestRecents()
        recents.alphaValue = 0
        recents.isHidden = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; recents.animator().alphaValue = 1 }
        window.makeFirstResponder(recents)
    }

    private func hideRecents() {
        guard !recents.isHidden else { return }
        recents.isHidden = true
        window.makeFirstResponder(stream)
    }

    private func pick(_ task: PhoneTask) {
        session.bringToFront(task: task.id)
        hideRecents()
    }

    // MARK: - Size (toolbox) and zoom (View menu: ⌘+ ⌘− ⌘0)

    @objc func sizePhone(_ sender: Any?) { setSize(.phone) }
    @objc func sizeFoldable(_ sender: Any?) { setSize(.foldable) }
    @objc func sizeTablet(_ sender: Any?) { setSize(.tablet) }

    private func setSize(_ new: PhoneSize) {
        guard new != size, !locked else { return }
        size = new
        let display = PhoneDisplaySize.forPreset(dp, density: PhoneInfo.densityDpi)
        session.resize(width: display.width, height: display.height, dpi: display.dpi)
        fitWindow(zoom: zoom, animate: true)
        updateSizes()
    }

    /// What's shown of the video: all but the status bar's rows.
    private func showVideoSize() {
        guard let videoPixels else { return }
        stream.videoSize = CGSize(width: videoPixels.width, height: videoPixels.height - CGFloat(cropPixels))
    }

    private func updateSizes() {
        for s in PhoneSize.allCases { tools.setSelected(s.rawValue, s == size) }
    }

    /// Window points per dp: saved per size, else what fits the screen.
    private var zoom: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "PhoneWindow.zoom.\(size.rawValue)")
        if saved > 0 { return saved }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 875)
        return PhoneSize.fittingZoom(shownDp, chrome: CGSize(width: SideToolbar.width, height: 0), screen: screen)
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(Self.zooms.first { $0 > zoom + 0.01 } ?? Self.zooms.last!) }
    @objc func zoomOut(_ sender: Any?) { setZoom(Self.zooms.last { $0 < zoom - 0.01 } ?? Self.zooms.first!) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ z: CGFloat) {
        UserDefaults.standard.set(Double(z), forKey: "PhoneWindow.zoom.\(size.rawValue)")
        fitWindow(zoom: z, animate: true)
    }

    /// The window: the screen at `z` plus the toolbar, its top edge kept (a phone held up grows down).
    private func fitWindow(zoom z: CGFloat, animate: Bool) {
        let content = NSSize(width: (shownDp.width * z).rounded() + SideToolbar.width, height: (shownDp.height * z).rounded())
        var frame = NSRect(x: window.frame.midX - content.width / 2, y: window.frame.maxY - content.height,
                           width: content.width, height: content.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
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
        // A phone's corner, scaled with the window.
        window.contentView?.layer?.cornerRadius = 30 * z
        window.invalidateShadow()
    }

    // MARK: - Visibility and keys

    private var lastVisibility: PhoneAppSession.Visibility?

    @objc private func updateVisibility() {
        let visibility: PhoneAppSession.Visibility =
            locked || !window.occlusionState.contains(.visible) ? .hidden
            : window.isKeyWindow && NSApp.isActive ? .focused : .visible
        guard visibility != lastVisibility else { return }
        lastVisibility = visibility
        session.setVisibility(visibility)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        PhoneWindowManager.shared?.focusedPhoneWindow()
        updateVisibility()
    }

    func windowDidResignKey(_ notification: Notification) {
        stream.cancelInput()
        updateVisibility()
    }

    @objc private func keyboardLayoutChanged() { session.setKeyboardLayout(AppWindowController.keyboardLayout()) }

    func windowWillClose(_ notification: Notification) {
        session.close() // its apps go back to the phone; the home screen ends
        NotificationCenter.default.removeObserver(self)
        onClosed(self)
    }
}

extension PhoneWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if [#selector(goBack(_:)), #selector(goHome(_:)), #selector(toggleRecents(_:))].contains(item.action) {
            return !locked && state == .showing
        }
        return true
    }
}

/// Borderless, yet a normal window: it can be key (typing), and closes and minimises.
final class PhoneWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) == false { return }
        close()
    }
    override func performMiniaturize(_ sender: Any?) { miniaturize(sender) }
    /// ⌘= is ⌘+ without Shift (View → Larger).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.charactersIgnoringModifiers == "=",
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            (delegate as? PhoneWindowController)?.zoomIn(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Recents

@MainActor @Observable
final class RecentsModel {
    /// nil while asking the phone.
    var tasks: [PhoneTask]?
    var snapshots: [Int32: NSImage] = [:]
    @ObservationIgnored var onPick: (PhoneTask) -> Void = { _ in }
    @ObservationIgnored var onRemove: (PhoneTask) -> Void = { _ in }
    @ObservationIgnored var onDismiss: () -> Void = {}
    @ObservationIgnored var onHome: () -> Void = {}
}

/// The phone window's Recents, drawn by the Mac: a card per app open in the window (its last
/// picture, icon and name), newest first. Click to switch, × to close the app, click outside or
/// Esc to go back.
struct RecentsView: View {
    @Bindable var model: RecentsModel
    let library: PhoneAppLibrary

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                .overlay(Color.black.opacity(0.35))
                .onTapGesture { model.onDismiss() }
            content
        }
        .onExitCommand { model.onDismiss() }
    }

    @ViewBuilder private var content: some View {
        if let tasks = model.tasks {
            if tasks.isEmpty {
                VStack(spacing: 14) {
                    Text("No recent apps").font(.headline).foregroundStyle(.white.opacity(0.8))
                    Button("Home") { model.onHome() }
                }
            } else {
                GeometryReader { geo in
                    let cardHeight = geo.size.height * 0.62
                    let cardWidth = cardHeight * geo.size.width / max(geo.size.height, 1)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(tasks) { task in
                                card(task, width: cardWidth, height: cardHeight)
                            }
                        }
                        .padding(.horizontal, (geo.size.width - cardWidth) / 2)
                        .frame(height: geo.size.height)
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small).tint(.white)
        }
    }

    private func card(_ task: PhoneTask, width: CGFloat, height: CGFloat) -> some View {
        let app = library.app(package: task.package)
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                if let app { Image(nsImage: library.icon(app)).resizable().frame(width: 20, height: 20) }
                Text(app?.label ?? task.package).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Button { model.onRemove(task); model.tasks?.removeAll { $0.id == task.id } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Close \(app?.label ?? "app")")
            }
            .frame(width: width)
            Group {
                if let image = model.snapshots[task.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.white.opacity(0.08))
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            .contentShape(Rectangle())
            .onTapGesture { model.onPick(task) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(app?.label ?? task.package)
    }
}
