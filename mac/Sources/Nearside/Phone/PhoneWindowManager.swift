import NearsideCore
import AppKit
import Carbon
@preconcurrency import CoreSpotlight
import CryptoKit
import UniformTypeIdentifiers

/// Owns the phone-app windows. While any is open Nearside is a regular app (Dock icon, ⌘-Tab,
/// menus), as phone apps should feel like Mac apps; with none it goes back to the menu bar.
/// Also the ways in: the launcher (⌥⌘P), the Dock menu and Spotlight, all behind the AuthGate.
@MainActor
final class PhoneWindowManager {
    /// For window-level actions ("Reopen") that need to open a new window.
    private(set) static weak var shared: PhoneWindowManager?

    private let engine: SyncEngine
    let library: PhoneAppLibrary
    private(set) var windows: [AppWindowController] = []
    private(set) lazy var launcher = PhoneLauncher(library: library, engine: engine) { [weak self] app in self?.open(app) }
    private let auth = AuthGate()
    private var hotKey: HotKey?
    private var opening: Set<String> = []

    init(engine: SyncEngine) {
        self.engine = engine
        library = PhoneAppLibrary(engine: engine)
        Self.shared = self
        library.onChange = { apps in PhoneSpotlight.index(apps, icon: { [weak self] in self?.library.iconPNG($0) }) }
        launcher.isLocked = { [weak self] in self?.auth.isLocked ?? true }
        auth.onLock = { [weak self] in self?.windows.forEach { $0.setLocked(true) } }
        // Option-Command-P from anywhere.
        hotKey = HotKey(keyCode: kVK_ANSI_P, modifiers: cmdKey | optionKey) { [weak self] in self?.toggleLauncher() }
    }

    func toggleLauncher() { launcher.toggle() }

    func showLauncher() { launcher.show() }

    func open(_ app: PhoneApp) {
        // One window per app: a second open brings the existing one forward.
        if let existing = windows.first(where: { $0.app.package == app.package }) {
            Task { if await auth.authenticate(opening: false) { unlockWindows(); existing.show() } }
            return
        }
        guard !opening.contains(app.package) else { return }
        opening.insert(app.package)
        Task { [weak self] in
            guard let self else { return }
            defer { opening.remove(app.package) }
            guard await auth.authenticate(opening: true) else { return }
            unlockWindows()
            guard let renderer = MetalRenderer(),
                  let controller = AppWindowController(app: app, engine: engine, renderer: renderer, icon: library.icons[app.id],
                                                       onClosed: { [weak self] in self?.closed($0) }) else { return }
            library.markUsed(app)
            windows.append(controller)
            updateActivationPolicy()
            controller.show()
        }
    }

    /// From Spotlight: the app's `pkg/activity`.
    func open(id: String) {
        if let app = library.app(id: id) { return open(app) }
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        open(PhoneApp(package: parts[0], activity: parts[1], label: parts[0]))
    }

    /// A covered window's "Unlock" button.
    func unlock() {
        Task { if await auth.authenticate(opening: false) { unlockWindows() } }
    }

    /// Settings: lowering when Touch ID is asked needs Touch ID.
    func changeAuthMode(to mode: AuthGate.Mode) async -> Bool {
        if mode < AuthGate.mode, !(await auth.confirm("change when Nearside asks before showing your phone's apps")) { return false }
        UserDefaults.standard.set(mode.rawValue, forKey: AuthGate.modeKey)
        return true
    }

    private func unlockWindows() { windows.forEach { $0.setLocked(false) } }

    /// The phone's "Stop" button: every window closes (its app is already back on the phone).
    func closeAll() {
        for controller in windows { controller.window.close() }
    }

    private func closed(_ controller: AppWindowController) {
        windows.removeAll { $0 === controller }
        // Let the close finish before the Dock icon goes (switching policy mid-close drops focus).
        DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
    }

    private func updateActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = windows.isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .regular { NSApp.activate() } // otherwise the menu bar may not switch over
    }

    /// The Dock icon's menu: the open phone apps, then "Open Phone App…".
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        for controller in windows {
            let item = NSMenuItem(title: controller.app.label, action: #selector(AppWindowController.bringForward(_:)), keyEquivalent: "")
            item.target = controller
            item.image = library.icons[controller.app.id].map(Self.menuIcon)
            menu.addItem(item)
        }
        if !windows.isEmpty { menu.addItem(.separator()) }
        let open = NSMenuItem(title: "Open Phone App…", action: #selector(AppDelegate.showPhoneLauncher(_:)), keyEquivalent: "")
        menu.addItem(open)
        return menu
    }

    static func menuIcon(_ image: NSImage) -> NSImage {
        let small = image.copy() as! NSImage
        small.size = NSSize(width: 16, height: 16)
        return small
    }
}

/// Phone apps in the Mac's Spotlight: "Instagram — Phone app" opens it in a window here.
enum PhoneSpotlight {
    static let domain = "phone-apps"
    static let enabledKey = "PhoneApps.spotlight"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    @MainActor
    static func index(_ apps: [PhoneApp], icon: (PhoneApp) -> Data?) {
        let index = CSSearchableIndex.default()
        guard enabled else {
            index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
            return
        }
        // Re-index only when the list or its icons changed.
        let signature = apps.map { "\($0.id)|\($0.label)|\($0.version)|\(icon($0) != nil)" }.joined(separator: "\n")
        let key = "PhoneApps.spotlightSignature"
        let hash = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        guard UserDefaults.standard.string(forKey: key) != hash else { return }
        let items = apps.map { app in
            let attributes = CSSearchableItemAttributeSet(contentType: .application)
            attributes.title = app.label
            attributes.displayName = app.label
            attributes.contentDescription = "Phone app · opens in a window on this Mac"
            attributes.keywords = ["phone", "android", app.package]
            attributes.thumbnailData = icon(app)
            return CSSearchableItem(uniqueIdentifier: app.id, domainIdentifier: domain, attributeSet: attributes)
        }
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { error in
                if let error { NSLog("Nearside: Spotlight indexing failed: \(error)") }
                else { NSLog("Nearside: \(items.count) phone apps in Spotlight") }
            }
        }
        UserDefaults.standard.set(hash, forKey: key)
    }

    static func remove() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
        UserDefaults.standard.removeObject(forKey: "PhoneApps.spotlightSignature")
    }
}
