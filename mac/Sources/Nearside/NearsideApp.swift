import NearsideCore
import CoreSpotlight
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

    /// Shown while phone-app windows are open (Nearside is then a regular app). In the menu-bar
    /// mode it's never visible, but its key equivalents still give the panel's text fields
    /// ⌘X/⌘C/⌘V/⌘A/⌘Z, and ⌘Q quits.
    @MainActor private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }

        _ = submenu("Nearside", [
            item("About Nearside", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Nearside", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Nearside", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = submenu("File", [
            item("Open Phone App…", #selector(AppDelegate.showPhoneLauncher(_:)), "p", [.command, .option]),
            item("Phone Window", #selector(AppDelegate.showPhoneWindow(_:)), "p", [.command, .option, .shift]),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        _ = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z"),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        _ = submenu("View", [
            item("Back", #selector(AppWindowController.goBack(_:)), "["),
            item("Home", #selector(PhoneWindowController.goHome(_:)), "1"),
            item("Recents", #selector(PhoneWindowController.toggleRecents(_:)), "2"),
            .separator(),
            item("Phone Size", #selector(PhoneWindowController.sizePhone(_:)), "1", [.command, .control]),
            item("Foldable Size", #selector(PhoneWindowController.sizeFoldable(_:)), "2", [.command, .control]),
            item("Tablet Size", #selector(PhoneWindowController.sizeTablet(_:)), "3", [.command, .control]),
            .separator(),
            item("Larger", #selector(PhoneWindowController.zoomIn(_:)), "+"),
            item("Smaller", #selector(PhoneWindowController.zoomOut(_:)), "-"),
            item("Actual Size", #selector(PhoneWindowController.actualSize(_:)), "0"),
            .separator(),
            item("Show Statistics", #selector(AppDelegate.toggleStatistics(_:)), "i", [.command, .option]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApplication.shared.windowsMenu = window
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
        openAppForTesting(engine)
        snapshotLauncherForTesting(engine)
        snapshotSetupForTesting(engine)
    }

    @objc func showPhoneLauncher(_ sender: Any?) { statusItem?.phoneApps.showLauncher() }

    @objc func showPhoneWindow(_ sender: Any?) { statusItem?.phoneApps.openPhoneWindow() }

    /// View → Show Statistics: the readout over every phone window (a menu checkmark when on).
    @objc func toggleStatistics(_ sender: Any?) {
        StatsOverlay.enabled.toggle()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { statusItem?.phoneApps.dockMenu() }

    /// A phone app picked in Spotlight.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        statusItem?.phoneApps.open(id: id)
        return true
    }

    /// Test hook: NEARSIDE_TEST_SETUP=<png> saves a setup page (NEARSIDE_TEST_SETUP_PAGE: welcome,
    /// permissions (default), phone) in light mode, or dark with NEARSIDE_TEST_DARK=1, after
    /// NEARSIDE_TEST_WAIT seconds (default 3) so the states have settled.
    private func snapshotSetupForTesting(_ engine: SyncEngine) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NEARSIDE_TEST_SETUP"] else { return }
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 620, height: 560), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let page: SetupWizard.Page = switch env["NEARSIDE_TEST_SETUP_PAGE"] {
        case "welcome": .welcome
        case "phone": .phone
        default: .permissions
        }
        let dark = env["NEARSIDE_TEST_DARK"] == "1"
        let view = NSHostingView(rootView: SetupWizard(engine: engine, close: {}, startPage: page).tint(Theme.accent))
        window.contentView = view
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : .white
        window.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(env["NEARSIDE_TEST_WAIT"] ?? "") ?? 3))
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            window.close()
        }
    }

    /// Test hook: NEARSIDE_TEST_LAUNCHER=<png> shows the launcher once connected and saves its
    /// picture (NEARSIDE_TEST_QUERY types a search; NEARSIDE_TEST_MOVES="down,right" moves).
    private func snapshotLauncherForTesting(_ engine: SyncEngine) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NEARSIDE_TEST_LAUNCHER"] else { return }
        Task { @MainActor in
            while engine.state != .connected { try? await Task.sleep(for: .milliseconds(300)) }
            let moves: [LauncherGrid.Move] = (env["NEARSIDE_TEST_MOVES"] ?? "").split(separator: ",").compactMap {
                switch $0 { case "up": .up; case "down": .down; case "left": .left; case "right": .right; default: nil }
            }
            await statusItem?.phoneApps.launcher.snapshotForTesting(to: URL(fileURLWithPath: path),
                                                                    query: env["NEARSIDE_TEST_QUERY"] ?? "", moves: moves)
        }
    }

    /// Test hook: NEARSIDE_OPEN_APP=<package> opens that phone app once the phone is connected
    /// (a comma-separated list opens several, a few seconds apart).
    private func openAppForTesting(_ engine: SyncEngine) {
        // NEARSIDE_TEST_LAYOUTS=1: log the phone's keyboard layouts (the Settings list).
        if ProcessInfo.processInfo.environment["NEARSIDE_TEST_LAYOUTS"] != nil {
            Task { @MainActor in
                while engine.state != .connected { try? await Task.sleep(for: .milliseconds(300)) }
                NSLog("Nearside: test layouts: \(await engine.phoneKeyboardLayouts() ?? [])")
            }
        }
        // NEARSIDE_OPEN_NOTIFICATION=<key>: that phone notification's "Open on Mac".
        if let key = ProcessInfo.processInfo.environment["NEARSIDE_OPEN_NOTIFICATION"] {
            Task { @MainActor in
                while engine.state != .connected { try? await Task.sleep(for: .milliseconds(300)) }
                try? await Task.sleep(for: .seconds(1))
                let pkg = key.split(separator: "|").dropFirst().first.map(String.init) ?? ""
                engine.onOpenNotificationOnMac?(key, pkg, "Test")
            }
            return
        }
        guard let list = ProcessInfo.processInfo.environment["NEARSIDE_OPEN_APP"] else { return }
        Task { @MainActor in
            while engine.state != .connected { try? await Task.sleep(for: .milliseconds(300)) }
            if list == "phone" { // the phone window
                _ = await engine.phoneApps() // the phone's shape
                statusItem?.phoneApps.openPhoneWindow()
                return
            }
            // NEARSIDE_OPEN_APP_DELAY=<s>: open later (with another app in front by then).
            let delay = Double(ProcessInfo.processInfo.environment["NEARSIDE_OPEN_APP_DELAY"] ?? "") ?? 1
            try? await Task.sleep(for: .seconds(delay))
            // NEARSIDE_OPEN_APP_GAP=<s>: between windows (default 4).
            let gap = Double(ProcessInfo.processInfo.environment["NEARSIDE_OPEN_APP_GAP"] ?? "") ?? 4
            for package in list.split(separator: ",").map(String.init) {
                if package == "phone" {
                    _ = await engine.phoneApps()
                    statusItem?.phoneApps.openPhoneWindow()
                    try? await Task.sleep(for: .seconds(gap))
                    continue
                }
                // "pkg/activity" opens that activity even if it isn't in the launcher (test screens).
                let parts = package.split(separator: "/", maxSplits: 1).map(String.init)
                let direct = parts.count == 2 ? PhoneApp(package: parts[0], activity: parts[1], label: "Test") : nil
                var found = direct
                if found == nil { found = await engine.phoneApps()?.first(where: { $0.package == package }) }
                guard let app = found else {
                    NSLog("Nearside: test hook: \(package) not found")
                    continue
                }
                statusItem?.openPhoneApp(app)
                try? await Task.sleep(for: .seconds(gap))
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
    private var shelf: DropShelfController?
    private lazy var messagesWindow = MessagesWindowController(engine: engine)
    private lazy var setupWindow = SetupWindowController(engine: engine)
    private(set) lazy var phoneApps = PhoneWindowManager(engine: engine)

    init(engine: SyncEngine) {
        self.engine = engine
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: PanelView(engine: engine, openMessages: { [weak self] in
            self?.popover.performClose(nil)
            self?.messagesWindow.show()
        }, openSetup: { [weak self] in
            self?.popover.performClose(nil)
            self?.setupWindow.show()
        }, openApps: { [weak self] in
            self?.popover.performClose(nil)
            self?.phoneApps.showLauncher()
        }).tint(Theme.accent))
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
        engine.onPhoneAppsStop = { [weak self] in self?.phoneApps.closeAll() }
        engine.onShareFailed = { [weak self] pkg, accepts in self?.phoneApps.shareFailed(package: pkg, accepts: accepts) }
        engine.onOpenNotificationOnMac = { [weak self] key, pkg, app in
            self?.phoneApps.openNotification(key: key, package: pkg, label: app)
        }
        _ = phoneApps // its hot key (⌥⌘P) works from launch

        // First run (or re-pairing needed): open the setup wizard straight away.
        if engine.state == .needsSetup {
            DispatchQueue.main.async { [weak self] in self?.setupWindow.show() }
        }
    }

    func openPhoneApp(_ app: PhoneApp) { phoneApps.open(app) }

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
            // The logo's mark: solid when connected, outlined when the phone isn't reachable.
            let image = Logo.menuBarMark(height: 13, outlined: engine.state != .connected)
            image.accessibilityDescription = engine.state == .connected ? "Nearside, connected" : "Nearside, not connected"
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

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleStatistics(_:)) { item.state = StatsOverlay.enabled ? .on : .off }
        return true
    }
}
