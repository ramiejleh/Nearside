import NearsideCore
import SwiftUI

/// A drop zone that slides in under the menu-bar icon while you drag files toward the top of
/// the screen. Needed because reaching the menu bar itself with a drag opens Mission Control
/// (Desktop & Dock → "Drag windows to top of screen…", on by default).
@MainActor
final class DropShelfController {
    private let engine: SyncEngine
    private let anchor: () -> NSRect? // the status button's frame on screen
    private let onDrop: ([URL]) -> Void
    private let model = ShelfModel()
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var dragChangeCount = -1
    private var dragHasFiles = false

    /// How close to the top of the screen a file drag must get before the shelf appears.
    private let reveal: CGFloat = 220

    init(engine: SyncEngine, anchor: @escaping () -> NSRect?, onDrop: @escaping ([URL]) -> Void) {
        self.engine = engine
        self.anchor = anchor
        self.onDrop = onDrop
        // Mouse events from other apps (Finder) need no special permission to observe.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragged() }
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragEnded() }
        } as Any)
    }

    private func dragged() {
        // Each new drag replaces the drag pasteboard; look at its contents once per drag.
        let pasteboard = NSPasteboard(name: .drag)
        if pasteboard.changeCount != dragChangeCount {
            dragChangeCount = pasteboard.changeCount
            dragHasFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        }
        guard dragHasFiles, engine.state == .connected else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return }
        if mouse.y > screen.frame.maxY - reveal { show(on: screen, near: mouse) }
    }

    private func dragEnded() {
        guard panel?.isVisible == true else { return }
        // performDragOperation can land just after the global mouse-up; hide a beat later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.hide() }
    }

    private func show(on screen: NSScreen, near mouse: NSPoint) {
        let panel = panel ?? makePanel()
        self.panel = panel
        model.phoneName = engine.phoneName
        guard !panel.isVisible else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame // below the menu bar
        // Under the menu-bar icon when it's on this screen, else under the pointer.
        let button = anchor().flatMap { NSMouseInRect(NSPoint(x: $0.midX, y: $0.midY), screen.frame, false) ? $0 : nil }
        let x = (button?.midX ?? mouse.x) - size.width / 2
        let origin = NSPoint(x: min(max(x, visible.minX + 8), visible.maxX - size.width - 8),
                             y: visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        model.hovering = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 260, height: 110)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let drop = FileDropView(frame: NSRect(origin: .zero, size: size))
        drop.canAccept = { [weak self] in self?.engine.state == .connected }
        drop.onHover = { [weak self] in self?.model.hovering = $0 }
        drop.onDrop = { [weak self] urls in
            self?.onDrop(urls)
            self?.hide()
        }
        let host = NSHostingView(rootView: ShelfView(model: model))
        host.frame = drop.bounds
        host.autoresizingMask = [.width, .height]
        drop.addSubview(host)
        panel.contentView = drop
        return panel
    }
}

@MainActor
@Observable
private final class ShelfModel {
    var hovering = false
    var phoneName = "phone"
}

private struct ShelfView: View {
    let model: ShelfModel

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: model.hovering ? "arrow.down.circle.fill" : "smartphone")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.green)
                .contentTransition(.symbolEffect(.replace))
            Text(model.hovering ? "Release to send" : "Drop to send to your \(model.phoneName)")
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: model.hovering ? [] : [6, 4]))
                .foregroundStyle(Color.green.opacity(model.hovering ? 0.9 : 0.6))
        }
        .scaleEffect(model.hovering ? 1.04 : 1)
        .animation(.snappy(duration: 0.18), value: model.hovering)
        .padding(4)
    }
}

/// Accepts file drags; used by the shelf and over the status button (which also needs clicks).
class FileDropView: NSView {
    var canAccept: () -> Bool = { false }
    var onHover: (Bool) -> Void = { _ in }
    var onDrop: ([URL]) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
