import NearsideCore
import NearsideMac
import AppKit
import SwiftUI

/// The phone window's notification panel, drawn by the Mac over the screen (Android's own shade
/// exists only on the phone's screen): the phone's current notifications, newest first. Click one
/// to open it in the phone window; its buttons and replies work as on the phone; × or a sideways
/// drag dismisses it (on the phone too). Esc or a click outside closes the panel.
struct NotificationPanel: View {
    let engine: SyncEngine
    let library: PhoneAppLibrary
    var onOpen: (PhoneNotification) -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.35))
                .onTapGesture { onClose() }
            VStack(spacing: 10) {
                header
                content
            }
            .padding(.top, 14)
        }
        .environment(\.colorScheme, .dark)
        .onExitCommand { onClose() }
    }

    private var header: some View {
        HStack {
            Text("Notifications").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            if !engine.phoneNotifications.isEmpty {
                Button("Clear All") { withAnimation(.easeOut(duration: 0.2)) { engine.clearPhoneNotifications() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.white.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var content: some View {
        if !engine.mirrorNotifications {
            empty("Phone notifications are off", "Turn on Show phone notifications in Settings to see them here.")
        } else if engine.state != .connected {
            empty("Your phone isn't connected", "Its notifications show here once it is.")
        } else if engine.phoneNotifications.isEmpty {
            empty("No notifications", nil)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(engine.phoneNotifications) { note in
                        NotificationCard(note: note, icon: icon(note.package), engine: engine) { onOpen(note) }
                            .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
                .animation(.easeOut(duration: 0.2), value: engine.phoneNotifications.map(\.key))
            }
            .scrollIndicators(.hidden)
        }
    }

    private func empty(_ title: String, _ detail: String?) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "bell.slash").font(.system(size: 26)).foregroundStyle(.white.opacity(0.5))
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 60)
    }

    /// The app's launcher icon, else the one the phone sent with a notification, else a symbol.
    private func icon(_ package: String) -> NSImage? {
        if let app = library.app(package: package) { return library.icon(app) }
        return PhoneNotification.iconURL(package: package).flatMap(NSImage.init(contentsOf:))
    }
}

/// One notification: open, buttons, reply, dismiss. Its colours follow the light or dark around it.
struct NotificationCard: View {
    let note: PhoneNotification
    let icon: NSImage?
    let engine: SyncEngine
    var open: () -> Void

    @State private var hovering = false
    @State private var offset: CGFloat = 0
    @State private var replying: Int?
    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Group {
                        if let icon { Image(nsImage: icon).resizable() } else { Image(systemName: "app.fill").resizable() }
                    }
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text(note.app).lineLimit(1)
                    Text("·")
                    Text(Self.age(note.posted))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Color.primary.opacity(0.6))
                if !note.title.isEmpty {
                    Text(note.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.primary).lineLimit(2)
                }
                if !note.text.isEmpty {
                    Text(note.text).font(.system(size: 12.5)).foregroundStyle(Color.primary.opacity(0.85)).lineLimit(4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            if let replying {
                replyField(replying)
            } else if !note.actions.isEmpty {
                actions
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(hovering ? 0.14 : 0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if hovering {
                HStack(spacing: 4) {
                    if !note.package.isEmpty {
                        Menu {
                            Button("Mute Notifications from \(note.app)") { mute() }
                        } label: {
                            Image(systemName: "ellipsis.circle.fill").font(.system(size: 16)).foregroundStyle(Color.primary.opacity(0.7))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More")
                    }
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(Color.primary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .padding(8)
            }
        }
        .offset(x: offset)
        .opacity(1 - min(abs(offset) / 220, 0.6))
        .gesture(DragGesture(minimumDistance: 12).onChanged { value in
            if abs(value.translation.width) > abs(value.translation.height) { offset = value.translation.width }
        }.onEnded { value in
            if abs(value.translation.width) > 90 { dismiss() } else { withAnimation(.spring(duration: 0.25)) { offset = 0 } }
        })
        .onHover { hovering = $0 }
        .contextMenu {
            if !note.package.isEmpty { Button("Mute Notifications from \(note.app)") { mute() } }
            Button("Dismiss") { dismiss() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(note.app): \(note.title). \(note.text)")
        .accessibilityAction(named: "Open") { open() }
        .accessibilityAction(named: "Dismiss") { dismiss() }
        .accessibilityAction(named: "Mute notifications from \(note.app)") { mute() }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            ForEach(Array(note.actions.enumerated()), id: \.offset) { index, action in
                Button(action.title) {
                    if action.isReply {
                        replying = index
                        replyFocused = true
                    } else {
                        engine.runPhoneNotificationAction(note.key, index: index)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.primary.opacity(0.14), in: Capsule())
            }
        }
    }

    private func replyField(_ index: Int) -> some View {
        HStack(spacing: 6) {
            TextField(note.actions[index].title, text: $reply)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.primary.opacity(0.12), in: Capsule())
                .focused($replyFocused)
                .onSubmit(send)
                .onExitCommand { replying = nil; reply = "" }
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                .buttonStyle(.plain)
                .foregroundStyle(reply.isEmpty ? Color.primary.opacity(0.3) : Color.primary)
                .disabled(reply.isEmpty)
                .help("Send")
        }
    }

    private func send() {
        guard let replying, !reply.isEmpty else { return }
        engine.runPhoneNotificationAction(note.key, index: replying, text: reply)
        self.replying = nil
        reply = ""
    }

    /// Never shows this app's notifications on this computer again (Settings turns it back on).
    private func mute() {
        withAnimation(.easeOut(duration: 0.2)) { engine.setApp(note.package, muted: true) }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) {
            offset = offset < 0 ? -400 : 400
            engine.dismissPhoneNotification(note.key)
        }
    }

    /// "now", "5m", "3h", else the day ("21 Nov").
    static func age(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 24 * 3600 { return "\(Int(seconds / 3600))h" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
