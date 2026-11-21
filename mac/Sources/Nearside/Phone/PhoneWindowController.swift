import NearsideCore
import AppKit
import SwiftUI

/// The phone window: a whole phone of its own on the Mac, separate from the real phone's screen.
/// Our home screen runs on its display, and apps opened there stay there. It looks like a phone:
/// borderless, rounded, phone-shaped; a bar appears when the pointer is at the top (drag, close,
/// Back, Home, Recents). The display keeps the phone's size in dp; making the window larger or
/// smaller only scales the picture, so apps never relayout.
@MainActor
final class PhoneWindowController: NSObject, NSWindowDelegate {
    let window: PhoneWindow
    private let session: PhoneAppSession
    private let stream: StreamView
    private let overlay = OverlayHostingView(rootView: AppWindowOverlay(state: .opening, label: "Phone"))
    private let recents: NSHostingView<RecentsView>
    private let recentsModel = RecentsModel()
    private let bar = PhoneHoverBar()
    private let library: PhoneAppLibrary
    private let onClosed: (PhoneWindowController) -> Void
    private var state: PhoneAppSession.State = .opening
    private var locked = false
    private var secure = false
    /// The phone's screen in dp (points at actual size).
    private let dp: CGSize

    private static let zoomKey = "PhoneWindow.zoom"
    private static let zooms: [CGFloat] = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.15, 1.3, 1.5]

    init?(engine: SyncEngine, library: PhoneAppLibrary, renderer: MetalRenderer, onClosed: @escaping (PhoneWindowController) -> Void) {
        self.library = library
        self.onClosed = onClosed
        dp = PhoneInfo.screenDp
        // The display: the phone's dp at 2 px per dp (crisp on Retina at actual size).
        let size = PhoneDisplaySize.forWindow(dp, scale: 2)
        session = engine.makePhoneWindowSession(width: size.width, height: size.height, dpi: size.dpi)

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let saved = UserDefaults.standard.double(forKey: Self.zoomKey)
        let zoom = saved > 0 ? saved : min(1, (screen.height * 0.82 / dp.height * 20).rounded(.down) / 20)
        window = PhoneWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: dp.width * zoom, height: dp.height * zoom)),
                             styleMask: [.borderless, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Phone"
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentAspectRatio = dp
        window.contentMinSize = NSSize(width: dp.width * 0.45, height: dp.height * 0.45)
        window.collectionBehavior.insert(.fullScreenNone)
        window.setFrameAutosaveName("PhoneWindow")
        if !window.setFrameUsingName("PhoneWindow") { window.center() }

        stream = StreamView(renderer: renderer)
        stream.macShortcuts = ["1", "2", "=", "+", "-", "0", "w", "m"]
        recents = NSHostingView(rootView: RecentsView(model: recentsModel, library: library))
        recents.isHidden = true

        let container = PhoneContentView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        for view in [stream, overlay, recents, bar] as [NSView] {
            container.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
            ])
            if view === bar {
                bar.heightAnchor.constraint(equalToConstant: PhoneHoverBar.height).isActive = true
            } else {
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true
            }
        }
        window.contentView = container
        super.init()
        window.delegate = self
        container.onHover = { [weak self] inside in self?.bar.setShown(inside) }
        updateCorners()

        bar.onClose = { [weak self] in self?.window.performClose(nil) }
        bar.onMinimize = { [weak self] in self?.window.miniaturize(nil) }
        bar.onBack = { [weak self] in self?.goBack(nil) }
        bar.onHome = { [weak self] in self?.goHome(nil) }
        bar.onRecents = { [weak self] in self?.toggleRecents(nil) }
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
        guard mode == "recents" || mode == "close" || mode == "bar" else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["NEARSIDE_TEST_WAIT"] ?? "") ?? 12))
            guard let self else { return }
            if mode == "close" { return window.performClose(nil) }
            if mode == "bar" {
                bar.setShown(true)
                try? await Task.sleep(for: .seconds(1))
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

    // MARK: - Sizes (View menu: ⌘+ ⌘− ⌘0)

    private var zoom: CGFloat { window.contentLayoutRect.width / dp.width }

    @objc func zoomIn(_ sender: Any?) { setZoom(Self.zooms.first { $0 > zoom + 0.01 } ?? Self.zooms.last!) }
    @objc func zoomOut(_ sender: Any?) { setZoom(Self.zooms.last { $0 < zoom - 0.01 } ?? Self.zooms.first!) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ z: CGFloat) {
        var frame = window.frame
        let size = NSSize(width: (dp.width * z).rounded(), height: (dp.height * z).rounded())
        // Keep the top edge where it is (as a phone held up would grow downwards).
        frame.origin.y += frame.height - size.height
        frame.origin.x += (frame.width - size.width) / 2
        frame.size = size
        window.setFrame(frame, display: true, animate: true)
    }

    func windowDidResize(_ notification: Notification) {
        updateCorners()
        UserDefaults.standard.set(Double(zoom), forKey: Self.zoomKey)
    }

    /// A phone's corner, scaled with the window.
    private func updateCorners() {
        window.contentView?.layer?.cornerRadius = 34 * window.contentLayoutRect.width / dp.width
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
        bar.setShown(false)
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

/// Tells the controller when the pointer is near the top, where the bar appears.
final class PhoneContentView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseMoved(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        onHover(bounds.height - y < PhoneHoverBar.height + 12)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) { onHover(false) }
}

/// The bar at the top of the phone window: close and minimise, Back / Home / Recents, and a
/// handle to drag the window by. It fades in when the pointer is at the top.
final class PhoneHoverBar: NSView {
    static let height: CGFloat = 40

    var onClose: () -> Void = {}
    var onMinimize: () -> Void = {}
    var onBack: () -> Void = {}
    var onHome: () -> Void = {}
    var onRecents: () -> Void = {}
    var subtitle: String? { didSet { note.stringValue = subtitle ?? ""; note.isHidden = subtitle == nil } }

    private let note = NSTextField(labelWithString: "")
    private var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor), effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor), effect.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        func button(_ symbol: String, _ label: String, _ action: Selector, size: CGFloat = 15) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
                .withSymbolConfiguration(.init(pointSize: size, weight: .medium))!, target: self, action: action)
            b.isBordered = false
            b.contentTintColor = .white
            b.toolTip = label
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }
        let close = button("xmark.circle.fill", "Close", #selector(close(_:)), size: 14)
        close.contentTintColor = NSColor(white: 1, alpha: 0.75)
        let minimize = button("minus.circle.fill", "Minimise", #selector(minimize(_:)), size: 14)
        minimize.contentTintColor = NSColor(white: 1, alpha: 0.75)
        let nav = NSStackView(views: [button("chevron.backward", "Back (⌘[)", #selector(back(_:))),
                                      button("circle", "Home (⌘1)", #selector(home(_:))),
                                      button("square.on.square", "Recents (⌘2)", #selector(recents(_:)))])
        nav.spacing = 26
        nav.translatesAutoresizingMaskIntoConstraints = false
        note.font = .systemFont(ofSize: 10)
        note.textColor = NSColor(white: 1, alpha: 0.7)
        note.isHidden = true
        note.translatesAutoresizingMaskIntoConstraints = false
        for v in [close, minimize, nav, note] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            minimize.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 8),
            minimize.centerYAnchor.constraint(equalTo: centerYAnchor),
            nav.centerXAnchor.constraint(equalTo: centerXAnchor),
            nav.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            note.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        alphaValue = 0
        setAccessibilityRole(.toolbar)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setShown(_ show: Bool) {
        guard show != shown else { return }
        shown = show
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            animator().alphaValue = show ? 1 : 0
        }
    }

    // Hidden, it lets clicks through to the phone; shown, its empty parts drag the window.
    override func hitTest(_ point: NSPoint) -> NSView? { shown ? super.hitTest(point) : nil }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    @objc private func close(_ sender: Any?) { onClose() }
    @objc private func minimize(_ sender: Any?) { onMinimize() }
    @objc private func back(_ sender: Any?) { onBack() }
    @objc private func home(_ sender: Any?) { onHome() }
    @objc private func recents(_ sender: Any?) { onRecents() }
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
