import NearsideCore
import SwiftUI

@main
struct NearsideApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        // Everything lives in the status item (see StatusItemController); a scene is required.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: SyncEngine?
    private var statusItem: StatusItemController?
    private let toast = ArrivalToastController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let engine = SyncEngine(apkURL: Bundle.main.url(forResource: "nearside", withExtension: "apk"))
        let toast = toast
        engine.onArrival = { [weak engine] item in
            toast.show(item, from: engine?.phoneName ?? "Phone")
        }
        engine.start()
        self.engine = engine
        statusItem = StatusItemController(engine: engine)
        // The placeholder Settings scene adds "Settings… ⌘," to the app menu; ⌘, belongs to the
        // panel's own settings page. (The rest of the menu stays: Edit gives text fields ⌘V.)
        DispatchQueue.main.async {
            for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
                for entry in menu.items where entry.keyEquivalent == "," { menu.removeItem(entry) }
            }
        }
    }
}

/// The menu-bar icon and its panel. Built on AppKit rather than `MenuBarExtra` so the icon can
/// take file drops: drag from Finder onto it to send to the phone (the panel closes as soon as
/// you click into Finder, so dropping onto the panel alone wouldn't be practical).
@MainActor
final class StatusItemController: NSObject {
    private let engine: SyncEngine
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(engine: SyncEngine) {
        self.engine = engine
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: PanelView(engine: engine))
        popover.contentSize = NSSize(width: 380, height: 540)

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(toggle)
        button.imagePosition = .imageLeading

        let drop = StatusDropView(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.canAccept = { [weak engine] in engine?.state == .connected }
        drop.onHover = { [weak button] inside in button?.highlight(inside) }
        drop.onDrop = { [weak self] urls in
            self?.engine.sendFiles(urls)
            self?.show() // so you can see it go
        }
        drop.onClick = { [weak button] in button?.performClick(nil) }
        button.addSubview(drop)

        updateIcon()
    }

    @objc private func toggle() {
        popover.isShown ? popover.performClose(nil) : show()
    }

    private func show() {
        guard let button = item.button, !popover.isShown else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Phone glyph plus the count of unseen phone clips; re-runs whenever those change.
    private func updateIcon() {
        withObservationTracking {
            let symbol = switch engine.state {
            case .connected: "smartphone"
            case .searching, .needsSetup: "antenna.radiowaves.left.and.right.slash"
            case .adbMissing: "exclamationmark.triangle"
            }
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Nearside")
            image?.isTemplate = true
            item.button?.image = image
            let unseen = engine.unseenIDs.count
            item.button?.title = unseen > 0 ? " \(unseen)" : ""
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
    }
}

/// Transparent overlay on the status button that accepts file drags and passes clicks through.
private final class StatusDropView: NSView {
    var canAccept: () -> Bool = { false }
    var onHover: (Bool) -> Void = { _ in }
    var onDrop: ([URL]) -> Void = { _ in }
    var onClick: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDown(with event: NSEvent) { onClick() }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(), !fileURLs(sender).isEmpty else { return [] }
        onHover(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHover(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHover(false)
        let urls = fileURLs(sender)
        guard canAccept(), !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }
}
