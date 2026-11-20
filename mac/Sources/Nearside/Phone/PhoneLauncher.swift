import NearsideCore
import AppKit
import SwiftUI

/// The launcher: a Spotlight-style floating panel (⌥⌘P from anywhere, or the menu-bar panel's
/// apps button) with search, recents, favourites and every app. Type to filter, arrows to move,
/// Return to open, Esc to dismiss; it goes away when you click elsewhere.
@MainActor
final class PhoneLauncher: NSObject, NSWindowDelegate {
    private let library: PhoneAppLibrary
    private let engine: SyncEngine
    private let open: (PhoneApp) -> Void
    private(set) var panel: LauncherPanel?
    private let model = LauncherModel()

    /// Whether phone apps are locked behind Touch ID right now: Recents (what you've been using)
    /// stay hidden until then.
    var isLocked: () -> Bool = { false }

    init(library: PhoneAppLibrary, engine: SyncEngine, open: @escaping (PhoneApp) -> Void) {
        self.library = library
        self.engine = engine
        self.open = open
    }

    var isShown: Bool { panel?.isVisible == true }

    func toggle() { isShown ? hide() : show() }

    func show() {
        let panel = panel ?? makePanel()
        model.query = ""
        model.selection = 0
        model.focusToken += 1
        model.hideRecents = isLocked()
        library.refresh()
        // Where Spotlight sits: centred, a little above the middle, on the screen in use.
        if let screen = NSScreen.main?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.minY + screen.height * 0.62 - size.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> LauncherPanel {
        let panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 664, height: 540),
                                  styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.hide() }

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: LauncherView(library: library, engine: engine, model: model) { [weak self] app in
            self?.hide()
            self?.open(app)
        })
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        self.panel = panel
        return panel
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    /// Test hook: shows the launcher (typing `query`, moving with `moves`) and saves what it draws.
    func snapshotForTesting(to url: URL, query: String, moves: [LauncherGrid.Move]) async {
        show()
        try? await Task.sleep(for: .seconds(6)) // the list and icons arrive
        model.query = query
        try? await Task.sleep(for: .milliseconds(300))
        let sections = query.isEmpty ? [model.hideRecents ? 0 : library.recents(LauncherView.columns).count, library.favouriteApps().count, library.apps.count]
            : [library.search(query).count]
        let grid = LauncherGrid(sections: sections.filter { $0 > 0 }, columns: LauncherView.columns)
        for move in moves { model.selection = grid.moving(model.selection, move) }
        try? await Task.sleep(for: .milliseconds(500))
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        NSLog("Nearside: launcher snapshot \(url.path): \(library.apps.count) apps, \(library.icons.count) icons, recents \(library.recents().map(\.label))")
    }
}

/// Becomes key without activating Nearside (like Spotlight), so the app you were in stays
/// frontmost until you open something.
final class LauncherPanel: NSPanel {
    var onEscape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape() }
}

@MainActor @Observable
final class LauncherModel {
    var query = ""
    var selection = 0
    var hideRecents = false
    /// Bumped on every show, so the search field takes focus again.
    var focusToken = 0
}

struct LauncherView: View {
    let library: PhoneAppLibrary
    let engine: SyncEngine
    @Bindable var model: LauncherModel
    let open: (PhoneApp) -> Void
    @FocusState private var searchFocused: Bool

    static let columns = 7

    private struct Section: Identifiable {
        let id: String
        let title: String
        let apps: [PhoneApp]
    }

    private var sections: [Section] {
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            return [Section(id: "results", title: "", apps: library.search(model.query))]
        }
        let all = Section(id: "all", title: "All Apps", apps: library.apps)
        return [Section(id: "recents", title: "Recents", apps: model.hideRecents ? [] : library.recents(Self.columns)),
                Section(id: "favourites", title: "Favourites", apps: library.favouriteApps()),
                all].filter { !$0.apps.isEmpty }
    }

    var body: some View {
        let sections = sections
        let grid = LauncherGrid(sections: sections.map(\.apps.count), columns: Self.columns)
        let flat = sections.flatMap(\.apps)
        VStack(spacing: 0) {
            searchField(flat: flat, grid: grid)
            Divider()
            content(sections: sections, flat: flat)
            if engine.state != .connected { notConnected }
        }
        .frame(width: 664, height: 540)
        .onChange(of: model.query) { model.selection = 0 }
        .onChange(of: model.focusToken, initial: true) { searchFocused = true }
    }

    private func searchField(flat: [PhoneApp], grid: LauncherGrid) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
            TextField("Open a phone app", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .regular))
                .focused($searchFocused)
                .onSubmit { if flat.indices.contains(model.selection) { open(flat[model.selection]) } }
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                    guard press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]) else { return .ignored }
                    let move: LauncherGrid.Move = switch press.key {
                    case .upArrow: .up
                    case .downArrow: .down
                    case .leftArrow: .left
                    default: .right
                    }
                    model.selection = grid.moving(model.selection, move)
                    return .handled
                }
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    @ViewBuilder
    private func content(sections: [Section], flat: [PhoneApp]) -> some View {
        if library.apps.isEmpty {
            VStack(spacing: 10) {
                switch library.status {
                case .failed:
                    Image(systemName: "iphone.slash").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text("Couldn't get your phone's apps").font(.headline)
                    Text("Check that your phone is connected.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Try Again") { library.refresh() }
                default:
                    ProgressView()
                    Text("Getting your phone's apps…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if flat.isEmpty {
            Text("No apps match “\(model.query)”").font(.title3).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        let starts = sections.indices.map { i in sections.prefix(i).reduce(0) { $0 + $1.apps.count } }
                        ForEach(Array(sections.enumerated()), id: \.element.id) { i, section in
                            sectionView(section, start: starts[i])
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
                .onChange(of: model.selection) { _, i in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(i) }
                }
            }
        }
    }

    private func sectionView(_ section: Section, start: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !section.title.isEmpty {
                Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(86), spacing: 2), count: Self.columns),
                      alignment: .leading, spacing: 4) {
                ForEach(Array(section.apps.enumerated()), id: \.element.id) { i, app in
                    LauncherCell(app: app, icon: library.icon(app), selected: model.selection == start + i)
                        .id(start + i)
                        .onTapGesture { open(app) }
                        .contextMenu {
                            Button("Open") { open(app) }
                            Button(library.isFavourite(app) ? "Remove from Favourites" : "Add to Favourites") {
                                library.toggleFavourite(app)
                            }
                        }
                }
            }
        }
    }

    private var notConnected: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
            Text("Your phone isn't connected. Apps open once it is.")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5))
    }
}

private struct LauncherCell: View {
    let app: PhoneApp
    let icon: NSImage
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 60, height: 60)
            Text(app.label)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 4)
        }
        .frame(width: 84, height: 90)
        .help(app.label)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.28) : hovering ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.label)
        .accessibilityAddTraits(.isButton)
    }
}
