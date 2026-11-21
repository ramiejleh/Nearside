import NearsideCore
import AppKit
import SwiftUI

/// The phone window: a whole phone of its own on the Mac, separate from the real phone's screen.
/// Our home screen runs on its display, and apps opened there stay there. It looks like a phone:
/// borderless and rounded, with a permanent bar above the screen (never over it): close,
/// minimise, Back / Home / Recents, and the toolbox's size (Phone / Foldable / Tablet). The
/// display keeps the size's dp; Larger / Smaller only scale the picture.
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
    private let bar = PhoneHoverBar()
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

    init?(engine: SyncEngine, library: PhoneAppLibrary, renderer: MetalRenderer, onClosed: @escaping (PhoneWindowController) -> Void) {
        self.library = library
        self.onClosed = onClosed
        let size = PhoneSize(rawValue: UserDefaults.standard.string(forKey: "PhoneWindow.size") ?? "") ?? .phone
        // The display: the size's dp at 2 px per dp (crisp on Retina at actual size).
        let display = PhoneDisplaySize.forWindow(size.dp(phone: PhoneInfo.screenDp), scale: 2)
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
        // All in the window first: constraints between views need a common ancestor (pinning the
        // screen to a bar not added yet threw, through a Swift Task, and crashed the app later).
        for view in [stream, overlay, recents, bar] as [NSView] { container.addSubview(view) }
        for view in [stream, overlay, recents, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            // The bar on top, the screen under it: nothing covers the app.
            if view === bar {
                bar.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
                bar.heightAnchor.constraint(equalToConstant: PhoneHoverBar.height).isActive = true
            } else {
                view.topAnchor.constraint(equalTo: bar.bottomAnchor).isActive = true
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true
            }
        }
        window.contentView = container
        super.init()
        window.delegate = self
        fitWindow(zoom: zoom, animate: false)
        if !placed { window.center() }

        bar.onClose = { [weak self] in self?.window.performClose(nil) }
        bar.onMinimize = { [weak self] in self?.window.miniaturize(nil) }
        bar.onBack = { [weak self] in self?.goBack(nil) }
        bar.onHome = { [weak self] in self?.goHome(nil) }
        bar.onRecents = { [weak self] in self?.toggleRecents(nil) }
        bar.onSize = { [weak self] new in self?.setSize(new) }
        bar.size = size
        recentsModel.onPick = { [weak self] task in self?.pick(task) }
        recentsModel.onRemove = { [weak self] task in self?.session.remove(task: task.id) }
        recentsModel.onDismiss = { [weak self] in self?.hideRecents() }
        recentsModel.onHome = { [weak self] in self?.goHome(nil) }

        session.onFrame = { [renderer] frame in renderer.show(frame) }
        session.onState = { [weak self] state in self?.render(state) }
        session.onVideoSize = { [weak self] size in self?.stream.videoSize = size }
        session.onThermal = { [weak self] reduced in self?.bar.subtitle = reduced ? "Lower quality: your phone is warm" : nil }
        session.onSecure = { [weak self] on in
            guard let self else { return }
            secure = on
            render(state)
        }
        session.onTasks = { [weak self] tasks in self?.recentsModel.tasks = tasks }
        session.onSnapshot = { [weak self] task, jpeg in self?.recentsModel.snapshots[task] = NSImage(data: jpeg) }
        stream.session = session
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
        guard new != size, !locked else { bar.size = size; return }
        size = new
        let display = PhoneDisplaySize.forWindow(dp, scale: 2)
        session.resize(width: display.width, height: display.height, dpi: display.dpi)
        fitWindow(zoom: zoom, animate: true)
        bar.size = new
    }

    /// Window points per dp: saved per size, else what fits the screen.
    private var zoom: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "PhoneWindow.zoom.\(size.rawValue)")
        if saved > 0 { return saved }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 875)
        return PhoneSize.fittingZoom(dp, chrome: PhoneHoverBar.height, screen: screen)
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(Self.zooms.first { $0 > zoom + 0.01 } ?? Self.zooms.last!) }
    @objc func zoomOut(_ sender: Any?) { setZoom(Self.zooms.last { $0 < zoom - 0.01 } ?? Self.zooms.first!) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ z: CGFloat) {
        UserDefaults.standard.set(Double(z), forKey: "PhoneWindow.zoom.\(size.rawValue)")
        fitWindow(zoom: z, animate: true)
    }

    /// The window: the bar plus the screen at `z`, its top edge kept (a phone held up grows down).
    private func fitWindow(zoom z: CGFloat, animate: Bool) {
        let content = NSSize(width: (dp.width * z).rounded(), height: (dp.height * z).rounded() + PhoneHoverBar.height)
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

/// The phone window's permanent bar, above the screen: close and minimise, Back / Home /
/// Recents, the toolbox's size switch, and a handle to drag the window by (its empty parts).
final class PhoneHoverBar: NSView {
    static let height: CGFloat = 40

    var onClose: () -> Void = {}
    var onMinimize: () -> Void = {}
    var onBack: () -> Void = {}
    var onHome: () -> Void = {}
    var onRecents: () -> Void = {}
    var onSize: (PhoneSize) -> Void = { _ in }
    var size: PhoneSize = .phone {
        didSet { sizes.selectedSegment = PhoneSize.allCases.firstIndex(of: size) ?? 0 }
    }
    var subtitle: String? {
        didSet {
            note.stringValue = subtitle ?? ""
            note.isHidden = subtitle == nil
            toolTip = subtitle
        }
    }

    private let note = NSTextField(labelWithString: "")
    private let sizes = NSSegmentedControl()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        func button(_ symbol: String, _ label: String, _ action: Selector, size: CGFloat = 14) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
                .withSymbolConfiguration(.init(pointSize: size, weight: .medium))!, target: self, action: action)
            b.isBordered = false
            b.contentTintColor = .white
            b.toolTip = label
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }
        let close = button("xmark.circle.fill", "Close", #selector(close(_:)), size: 13)
        close.contentTintColor = NSColor(white: 1, alpha: 0.7)
        let minimize = button("minus.circle.fill", "Minimise", #selector(minimize(_:)), size: 13)
        minimize.contentTintColor = NSColor(white: 1, alpha: 0.7)
        let nav = NSStackView(views: [button("chevron.backward", "Back (⌘[)", #selector(back(_:))),
                                      button("circle", "Home (⌘1)", #selector(home(_:))),
                                      button("square.on.square", "Recents (⌘2)", #selector(recents(_:)))])
        nav.spacing = 20
        nav.translatesAutoresizingMaskIntoConstraints = false
        // The toolbox: the size, as small icons.
        sizes.segmentCount = PhoneSize.allCases.count
        for (i, s) in PhoneSize.allCases.enumerated() {
            sizes.setImage(NSImage(systemSymbolName: s.symbol, accessibilityDescription: s.title)!
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)), forSegment: i)
            sizes.setToolTip("\(s.title) size", forSegment: i)
            sizes.setWidth(24, forSegment: i)
        }
        sizes.trackingMode = .selectOne
        sizes.segmentStyle = .separated
        sizes.controlSize = .small
        sizes.appearance = NSAppearance(named: .darkAqua)
        sizes.target = self
        sizes.action = #selector(sizePicked(_:))
        sizes.translatesAutoresizingMaskIntoConstraints = false
        note.font = .systemFont(ofSize: 9)
        note.textColor = NSColor(white: 1, alpha: 0.6)
        note.isHidden = true
        note.translatesAutoresizingMaskIntoConstraints = false
        for v in [close, minimize, nav, sizes, note] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            minimize.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 6),
            minimize.centerYAnchor.constraint(equalTo: centerYAnchor),
            nav.centerXAnchor.constraint(equalTo: centerXAnchor),
            nav.centerYAnchor.constraint(equalTo: centerYAnchor),
            sizes.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sizes.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.leadingAnchor.constraint(equalTo: minimize.trailingAnchor, constant: 8),
            note.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.toolbar)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Its empty parts drag the window (it's borderless).
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    @objc private func close(_ sender: Any?) { onClose() }
    @objc private func minimize(_ sender: Any?) { onMinimize() }
    @objc private func back(_ sender: Any?) { onBack() }
    @objc private func home(_ sender: Any?) { onHome() }
    @objc private func recents(_ sender: Any?) { onRecents() }
    @objc private func sizePicked(_ sender: NSSegmentedControl) { onSize(PhoneSize.allCases[max(0, sender.selectedSegment)]) }
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
