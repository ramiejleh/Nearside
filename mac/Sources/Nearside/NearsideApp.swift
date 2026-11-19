import NearsideCore
import SwiftUI

/// Plain AppKit entry point. A SwiftUI `App` must declare a scene, and the only invisible-ish
/// one (an empty `Settings`) still popped up as an empty "Nearside Settings" window.
@main
enum NearsideMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu-bar app: no Dock icon
        app.mainMenu = makeMainMenu()
        app.run()
    }

    /// Never visible for a menu-bar app, but its key equivalents are what give the panel's
    /// text fields ⌘X/⌘C/⌘V/⌘A/⌘Z, and ⌘Q quits.
    @MainActor private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit Nearside", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
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
    private var shelf: DropShelfController?
    private lazy var messagesWindow = MessagesWindowController(engine: engine)

    init(engine: SyncEngine) {
        self.engine = engine
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: PanelView(engine: engine, openMessages: { [weak self] in
            self?.popover.performClose(nil)
            self?.messagesWindow.show()
        }))
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

        shelf = DropShelfController(engine: engine,
                                    anchor: { [weak button] in button?.window?.frame },
                                    onDrop: { [weak self] urls in
                                        self?.engine.sendFiles(urls)
                                        self?.show()
                                    })

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

/// Transparent overlay on the status button: takes file drops and passes clicks through.
private final class StatusDropView: FileDropView {
    var onClick: () -> Void = {}
    override func mouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDown(with event: NSEvent) { onClick() }
}
