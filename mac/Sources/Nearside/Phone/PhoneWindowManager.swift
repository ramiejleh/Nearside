import NearsideCore
import AppKit
import SwiftUI

/// Owns the phone-app windows. While any is open Nearside is a regular app (Dock icon, ⌘-Tab),
/// as phone apps should feel like Mac apps; with none it goes back to living in the menu bar.
@MainActor
final class PhoneWindowManager {
    /// For window-level actions ("Reopen") that need to open a new window.
    private(set) static weak var shared: PhoneWindowManager?

    private let engine: SyncEngine
    private var windows: [AppWindowController] = []
    private var picker: NSWindow?

    init(engine: SyncEngine) {
        self.engine = engine
        Self.shared = self
    }

    func open(_ app: PhoneApp) {
        // One window per app: a second open brings the existing one forward.
        if let existing = windows.first(where: { $0.app.package == app.package }) {
            existing.show()
            return
        }
        guard let renderer = MetalRenderer(),
              let controller = AppWindowController(app: app, engine: engine, renderer: renderer,
                                                   onClosed: { [weak self] in self?.closed($0) }) else { return }
        windows.append(controller)
        updateActivationPolicy()
        controller.show()
    }

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

    // MARK: - Picker (a plain list for now; the designed launcher replaces it)

    func showPicker() {
        if let picker {
            picker.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Open a Phone App"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AppPickerView(engine: engine) { [weak self, weak window] app in
            window?.close()
            self?.open(app)
        })
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        picker = window
    }
}

struct AppPickerView: View {
    let engine: SyncEngine
    let open: (PhoneApp) -> Void
    @State private var apps: [PhoneApp]?
    @State private var query = ""
    @State private var selection: PhoneApp.ID?

    private var filtered: [PhoneApp] {
        guard let apps else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? apps : apps.filter { $0.label.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
                .onSubmit { if let first = filtered.first { open(first) } }
            Divider()
            if apps == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, selection: $selection) { app in
                    Text(app.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(app) }
                        .tag(app.id)
                }
                .onKeyPress(.return) {
                    guard let id = selection, let app = filtered.first(where: { $0.id == id }) else { return .ignored }
                    open(app)
                    return .handled
                }
            }
        }
        .task { apps = await engine.phoneApps() }
    }
}
