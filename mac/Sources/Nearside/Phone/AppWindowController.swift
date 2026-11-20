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
    private let overlay = NSHostingView(rootView: AppWindowOverlay(state: .opening, label: ""))
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
        state = new
        overlay.rootView = AppWindowOverlay(state: new, label: app.label, reopen: { [weak self] in self?.reopen() },
                                            close: { [weak self] in self?.window.close() })
        overlay.isHidden = new == .showing
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
        session.setVisible(window.occlusionState.contains(.visible))
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
