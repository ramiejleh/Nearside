import AppKit
import NearsideCore
import NearsideMac
import SwiftUI

/// The phone's calls on the Mac:
/// - ringing: a card at the top right like macOS's own (Answer, Decline, or decline with a text);
/// - in a call (answered anywhere): a card pinned under the menu-bar icon until it ends, with the
///   time, Mute and End, so it's always clear a call is going on. Not while the call's app is open
///   in a Mac window: that window shows the call.
@MainActor
final class CallPanelController {
    private let engine: SyncEngine
    private let anchor: () -> NSRect? // the status button's frame on screen
    private var ringPanel: NSPanel?
    private var callPanel: NSPanel?
    private var ringShown: String?
    private var callShown: String?
    private var ring: Timer?

    init(engine: SyncEngine, anchor: @escaping () -> NSRect?) {
        self.engine = engine
        self.anchor = anchor
        update()
    }

    private func update() {
        withObservationTracking {
            let calls = engine.calls
            if let call = calls.ringing { showRinging(call) } else { ringShown = nil; Self.hide(ringPanel) }
            if let call = calls.pinned { showOngoing(call) } else { callShown = nil; Self.hide(callPanel) }
            ringing(calls.ringing?.state == .incoming && engine.ringOnMac)
        } onChange: { [weak self] in
            Task { @MainActor in self?.update() }
        }
    }

    private func showRinging(_ call: PhoneCall) {
        let panel = ringPanel ?? Self.makePanel()
        ringPanel = panel
        guard ringShown != call.key || !panel.isVisible else { return } // the card follows the call itself
        ringShown = call.key
        let host = NSHostingView(rootView: RingingCard(engine: engine, key: call.key, onResize: { [weak self] in self?.fitRinging() })
            .tint(Theme.accent))
        panel.contentView = host
        guard let screen = NSScreen.main else { return }
        let size = host.fittingSize
        let frame = screen.visibleFrame
        Self.present(panel, at: NSPoint(x: frame.maxX - size.width - 14, y: frame.maxY - size.height - 10), size: size)
    }

    private func showOngoing(_ call: PhoneCall) {
        let panel = callPanel ?? Self.makePanel()
        callPanel = panel
        guard callShown != call.key || !panel.isVisible else { return }
        callShown = call.key
        let host = NSHostingView(rootView: InCallCard(engine: engine, key: call.key).tint(Theme.accent))
        panel.contentView = host
        guard let screen = NSScreen.main else { return }
        let size = host.fittingSize
        let visible = screen.visibleFrame
        // Under the menu-bar icon when it's on this screen (like the drop shelf), else top right.
        let button = anchor().flatMap { NSMouseInRect(NSPoint(x: $0.midX, y: $0.midY), screen.frame, false) ? $0 : nil }
        let x = (button?.midX ?? visible.maxX) - size.width / 2
        let origin = NSPoint(x: min(max(x, visible.minX + 8), visible.maxX - size.width - 8), y: visible.maxY - size.height - 6)
        Self.present(panel, at: origin, size: size)
    }

    /// The ringing card grew or shrank (the replies): keep its top edge where it is.
    private func fitRinging() {
        guard let panel = ringPanel, let host = panel.contentView else { return }
        let height = host.fittingSize.height
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
    }

    private static func present(_ panel: NSPanel, at origin: NSPoint, size: NSSize) {
        panel.setFrame(NSRect(origin: NSPoint(x: origin.x, y: origin.y + 10), size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }

    private static func hide(_ panel: NSPanel?) {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    /// A soft ring every few seconds while it rings (the phone rings too).
    private func ringing(_ on: Bool) {
        if !on { ring?.invalidate(); ring = nil; return }
        guard ring == nil else { return }
        let sound = NSSound(named: "Submarine")
        sound?.play()
        ring = Timer.scheduledTimer(withTimeInterval: 2.6, repeats: true) { _ in sound?.play() }
    }

    private static func makePanel() -> NSPanel {
        let panel = CallNSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true // only for typing a reply
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }
}

/// Takes keys (for the reply field) without making Nearside the active app.
private final class CallNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private extension PhoneCall {
    var title: String { name.isEmpty ? (number ?? "Unknown caller") : name }
    var kind: String { number != nil || package.hasSuffix(".dialer") ? "Phone call" : "\(app) call" }
}

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }
}

struct RingingCard: View {
    let engine: SyncEngine
    let key: String
    let onResize: () -> Void
    @State private var replying = false
    @State private var reply = ""

    private static let quickReplies = ["Can't talk now. I'll call you back.", "I'll call you later.", "On my way."]

    var body: some View {
        if let call = engine.calls.calls.first(where: { $0.key == key }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    CallerPhoto(call: call, size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(call.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        Text(call.state == .screening ? "\(call.kind) · screening" : call.kind)
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    HStack(spacing: 8) {
                        if call.number != nil, engine.textMessages, call.can.contains(.decline) {
                            RoundButton(symbol: "message.fill", color: .gray, help: "Decline with a text") {
                                withAnimation(.easeOut(duration: 0.15)) { replying.toggle() }
                            }
                        }
                        if call.can.contains(.decline) {
                            RoundButton(symbol: "phone.down.fill", color: .red, help: "Decline") { engine.calls.act(.decline, on: call) }
                        }
                        if call.can.contains(.answer) {
                            RoundButton(symbol: "phone.fill", color: .green, help: "Answer") { answer(call) }
                        }
                    }
                }
                if replying, let number = call.number {
                    replies(to: number, call: call)
                }
            }
            .padding(12)
            .frame(width: 360, alignment: .leading)
            .modifier(CardBackground())
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: replying) { DispatchQueue.main.async(execute: onResize) }
        }
    }

    private func replies(to number: String, call: PhoneCall) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.quickReplies, id: \.self) { text in
                Button { decline(call, sending: text, to: number) } label: {
                    Text(text).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            TextField("Write a reply…", text: $reply)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit {
                    let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { decline(call, sending: text, to: number) }
                }
        }
    }

    /// Answered here, it's talked here: a phone call's sound comes to this Mac (PhoneCalls), and
    /// an app's call opens in a Mac window (its sound and this Mac's microphone go with it).
    private func answer(_ call: PhoneCall) {
        engine.calls.act(.answer, on: call)
        guard !engine.calls.isPhoneCall(call) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            engine.onOpenNotificationOnMac?(call.key, call.package, call.app)
        }
    }

    private func decline(_ call: PhoneCall, sending text: String, to number: String) {
        engine.messages.send(text, to: number)
        engine.calls.act(.decline, on: call)
    }
}

/// Pinned under the menu-bar icon for as long as a call goes on.
struct InCallCard: View {
    let engine: SyncEngine
    let key: String

    var body: some View {
        if let call = engine.calls.calls.first(where: { $0.key == key }) {
            HStack(spacing: 10) {
                CallerPhoto(call: call, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(call.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        let place = engine.calls.isPhoneCall(call)
                            ? (engine.calls.audioOnMac ? "On this Mac" : "On your \(engine.phoneName)") : call.kind
                        if let since = call.since {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text("\(place) · \(Self.duration(context.date.timeIntervalSince(since)))").monospacedDigit()
                            }
                        } else {
                            Text(place)
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if engine.calls.isPhoneCall(call) {
                    let here = engine.calls.audioOnMac
                    RoundButton(symbol: here ? "iphone" : "laptopcomputer", color: .gray,
                                help: here ? "Talk on your \(engine.phoneName)" : "Talk on this Mac", size: 28) {
                        engine.calls.moveAudio(toMac: !here)
                    }
                } else {
                    // An app's call (this card only shows while it has no Mac window): its call
                    // screen into a window here, where this Mac's sound and microphone take over.
                    RoundButton(symbol: "laptopcomputer", color: .gray, help: "Talk on this Mac", size: 28) {
                        engine.onOpenNotificationOnMac?(call.key, call.package, call.app)
                    }
                }
                let muted = engine.calls.muted
                RoundButton(symbol: muted ? "mic.slash.fill" : "mic.fill", color: muted ? .orange : .gray,
                            help: muted ? "Unmute your phone's microphone" : "Mute your phone's microphone", size: 28) {
                    engine.calls.setMuted(!muted)
                }
                if call.can.contains(.hangup) {
                    RoundButton(symbol: "phone.down.fill", color: .red, help: "End call", size: 28) { engine.calls.act(.hangup, on: call) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 300, alignment: .leading)
            .modifier(CardBackground())
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct CallerPhoto: View {
    let call: PhoneCall
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.gray.opacity(0.35).gradient)
            if let data = call.photo, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.42)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct RoundButton: View {
    let symbol: String
    let color: Color
    let help: String
    var size: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.41, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(color.gradient, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
