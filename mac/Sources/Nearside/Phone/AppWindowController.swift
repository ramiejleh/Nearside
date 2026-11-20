import NearsideCore
import AppKit
import SwiftUI

/// One phone app in a native Mac window. Resizing the window resizes the app's display on the
/// phone, so the app lays itself out again (as a Mac app would) instead of being scaled.
@MainActor
final class AppWindowController: NSObject, NSWindowDelegate {
    let app: PhoneApp
    let window: NSWindow
    private let session: PhoneAppSession
    private let stream: StreamView
    private let overlay = OverlayHostingView(rootView: AppWindowOverlay(state: .opening, label: ""))
    private var state: PhoneAppSession.State = .opening
    private var resizeWork: DispatchWorkItem?
    private let onClosed: (AppWindowController) -> Void

    /// Phone-shaped (9:20) and 80 % of the screen's height, unless this app has a saved size.
    init?(app: PhoneApp, engine: SyncEngine, renderer: MetalRenderer, onClosed: @escaping (AppWindowController) -> Void) {
        self.app = app
        self.onClosed = onClosed
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = (screen.height * 0.8).rounded()
        let content = NSRect(x: 0, y: 0, width: (height * 9 / 20).rounded(), height: height)
        window = NSWindow(contentRect: content, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = app.label
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 280, height: 360)
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

        let scale = window.backingScaleFactor
        let size = PhoneDisplaySize.forWindow(window.contentLayoutRect.size, scale: scale)
        session = engine.makePhoneAppSession(app, width: size.width, height: size.height, dpi: size.dpi)
        super.init()
        window.delegate = self
        installToolbar()
        render(.opening)

        session.onFrame = { [renderer] frame in renderer.show(frame) }
        session.onState = { [weak self] state in self?.render(state) }
        session.onVideoSize = { [weak self] size in self?.stream.videoSize = size }
        stream.onTouch = { [weak self] action, x, y in self?.session.touch(action, x: x, y: y) }
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
        if new == .showing, state != .showing { testInputIfAsked() }
        state = new
        overlay.rootView = AppWindowOverlay(state: new, label: app.label, reopen: { [weak self] in self?.reopen() },
                                            close: { [weak self] in self?.window.close() })
        overlay.isHidden = new == .showing
    }

    /// Test hook: NEARSIDE_TEST_INPUT=1 taps the middle, then drags up, through the same path
    /// as the mouse (StreamView.onTouch → session), so input can be checked without a person.
    private func testInputIfAsked() {
        guard let mode = ProcessInfo.processInfo.environment["NEARSIDE_TEST_INPUT"] else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, let touch = stream.onTouch else { return }
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
                touch(.move, 0.5, 0.8 - Float(i) * 0.025)
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

    func windowDidEndLiveResize(_ notification: Notification) {
        // Let the hand settle, then give the phone the window's new size.
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
        windowDidEndLiveResize(notification) // moved to a screen with a different scale
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
