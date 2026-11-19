import NearsideCore
import AppKit
import SwiftUI

/// A small card that slides in under the menu bar when a clip arrives from the phone.
/// Non-activating: it never takes focus from what you're doing. Click it to dismiss.
@MainActor
final class ArrivalToastController {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: 340, height: 86)

    func show(_ item: ClipItem, from phoneName: String) {
        guard UserDefaults.standard.object(forKey: "showArrivalToast") as? Bool ?? true else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: ToastView(item: item, phoneName: phoneName) { [weak self] in
            self?.hide()
        })

        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(x: frame.maxX - size.width - 14, y: frame.maxY - size.height - 10)
        let wasVisible = panel.isVisible && panel.alphaValue > 0
        panel.setFrame(NSRect(origin: NSPoint(x: origin.x, y: origin.y + (wasVisible ? 0 : 12)), size: size), display: true)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(NSRect(origin: origin, size: size), display: true)
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.alphaValue = 0
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }
}

private struct ToastView: View {
    let item: ClipItem
    let phoneName: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            SourceBadge(source: .android)
                .scaleEffect(1.15)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("From \(phoneName)")
                        .font(.system(size: 12, weight: .semibold))
                    Text("· copied to your Mac")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .foregroundStyle(.primary.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(width: 340, height: 86, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }
}
