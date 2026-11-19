import NearsideCore
import SwiftUI

/// A real window (not the panel): conversations take more room than a menu-bar popover has.
@MainActor
final class MessagesWindowController: NSObject, NSWindowDelegate {
    private let engine: SyncEngine
    private var window: NSWindow?

    init(engine: SyncEngine) {
        self.engine = engine
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        engine.messages.isOpen = true
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        engine.messages.isActive = false
        engine.messages.isOpen = false
    }

    func windowDidBecomeKey(_ notification: Notification) { engine.messages.isActive = true }
    func windowDidResignKey(_ notification: Notification) { engine.messages.isActive = false }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Messages"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 600, height: 380)
        window.contentView = NSHostingView(rootView: MessagesView(engine: engine))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Messages")
        return window
    }
}

struct MessagesView: View {
    let engine: SyncEngine
    @State private var composingNew = false

    private var store: MessagesStore { engine.messages }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { composingNew = true } label: { Label("New Message", systemImage: "square.and.pencil") }
                    .disabled(!available)
                    .help("New text message")
            }
        }
        .sheet(isPresented: $composingNew) {
            NewMessageSheet { address, text in
                store.send(text, to: address)
            }
        }
    }

    private var available: Bool { engine.state == .connected && engine.textMessages && store.problem == nil }

    @ViewBuilder private var sidebar: some View {
        if !available || !store.loaded {
            Color.clear
        } else if store.threads.isEmpty {
            ContentUnavailableView("No texts", systemImage: "message", description: Text("SMS conversations show up here."))
        } else {
            List(selection: Binding(get: { store.selected }, set: { store.selected = $0 })) {
                ForEach(store.threads) { thread in
                    ThreadRow(thread: thread).tag(thread.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder private var detail: some View {
        if engine.state != .connected {
            ContentUnavailableView("\(engine.phoneName) isn't connected", systemImage: "antenna.radiowaves.left.and.right.slash",
                                   description: Text("Texts appear once the phone is back on the same Wi-Fi."))
        } else if !engine.textMessages {
            ContentUnavailableView {
                Label("Text messages are off", systemImage: "message.badge")
            } description: {
                Text("Turn them on to read and send SMS from this Mac.")
            } actions: {
                Button("Turn On") { engine.textMessages = true }
            }
        } else if let problem = store.problem {
            ContentUnavailableView("Can't load texts", systemImage: "exclamationmark.bubble", description: Text(problem))
        } else if !store.loaded {
            ProgressView("Loading texts from your \(engine.phoneName)…")
        } else if let id = store.selected, let thread = store.threads.first(where: { $0.id == id }) {
            ConversationView(store: store, thread: thread)
        } else {
            ContentUnavailableView("Pick a conversation", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Plain SMS only: RCS chats stay in Google Messages (reply to those from their notifications)."))
        }
    }
}

private struct ThreadRow: View {
    let thread: MessagesStore.Thread

    var body: some View {
        HStack(spacing: 10) {
            Avatar(title: thread.title, isNumber: thread.name == nil)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.title)
                        .font(.system(size: 13, weight: thread.unread > 0 ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.shortDate(thread.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top) {
                    Text((thread.outgoing ? "You: " : "") + thread.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if thread.unread > 0 {
                        Text("\(thread.unread)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.green, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    static func shortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

private struct Avatar: View {
    let title: String
    let isNumber: Bool

    var body: some View {
        let initials = title.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        ZStack {
            Circle().fill(color.gradient)
            if isNumber || initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: 14)).foregroundStyle(.white)
            } else {
                Text(initials.uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 34, height: 34)
    }

    /// A stable colour per contact.
    private var color: Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .red]
        return palette[abs(title.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % palette.count]
    }
}

private struct ConversationView: View {
    let store: MessagesStore
    let thread: MessagesStore.Thread
    @State private var draft = ""

    private static let bottom = "bottom"

    var body: some View {
        VStack(spacing: 0) {
            if let messages = store.messages[thread.id] {
                transcript(messages)
                    .id(thread.id) // a fresh scroll view per conversation, starting at the bottom
            } else {
                // Wait for the messages instead of showing an empty list that then jumps.
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = store.sendError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
            Divider()
            ComposeBar(draft: $draft, placeholder: "Text message") {
                store.send(draft, to: thread.address)
                draft = ""
            }
        }
        .navigationTitle(thread.title)
        .navigationSubtitle(thread.name == nil ? "" : thread.address)
    }

    private func transcript(_ messages: [MessagesStore.Message]) -> some View {
        let layout = MessagesStore.layout(messages)
        return ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a lazy stack only estimates the height of unseen bubbles, so
                // "scroll to the bottom" stopped short. 150 messages lay out instantly.
                VStack(spacing: 0) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if layout[index].header {
                            Text(Self.heading(message.date))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, index == 0 ? 4 : 16)
                                .padding(.bottom, 6)
                        }
                        Bubble(message: message, position: layout[index])
                            // Tight within a run, roomier between runs.
                            .padding(.top, layout[index].first && !layout[index].header ? 10 : 2)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id) {
                // Once the new bubble is laid out: all the way down, time label included.
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
            }
        }
    }
}

extension ConversationView {
    /// "Today 14:32", "Yesterday 09:10", "Mon 18:02", "12 Nov 2026 at 08:15".
    static func heading(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.wide))) \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct Bubble: View {
    let message: MessagesStore.Message
    let position: MessagesStore.Layout

    var body: some View {
        HStack {
            if message.outgoing { Spacer(minLength: 60) }
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 3) {
                Text(message.body)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(message.outgoing ? .white : .primary)
                    .background(message.outgoing ? AnyShapeStyle(Color.green.gradient) : AnyShapeStyle(.quaternary),
                                in: shape)
                    .opacity(message.pending ? 0.6 : 1)
                    .help(message.date.formatted(date: .abbreviated, time: .shortened))
                // Status/time once per run, under its last bubble (always for problems).
                if position.last || message.failed || message.pending {
                    HStack(spacing: 4) {
                        if message.failed {
                            Label("Not sent", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                        } else if message.pending {
                            Text("Sending…")
                        } else {
                            Text(message.date.formatted(date: .omitted, time: .shortened))
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                }
            }
            if !message.outgoing { Spacer(minLength: 60) }
        }
    }

    /// Round outside, tighter where bubbles of the same run meet (like Messages).
    private var shape: UnevenRoundedRectangle {
        let big: CGFloat = 17, small: CGFloat = 5
        let top = position.first ? big : small, bottom = position.last ? big : small
        return message.outgoing
            ? UnevenRoundedRectangle(topLeadingRadius: big, bottomLeadingRadius: big,
                                     bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                     bottomTrailingRadius: big, topTrailingRadius: big, style: .continuous)
    }
}

private struct ComposeBar: View {
    @Binding var draft: String
    let placeholder: String
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(canSend ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (⌘↩)")
        }
        .padding(12)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard canSend else { return }
        onSend()
    }
}

private struct NewMessageSheet: View {
    let onSend: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Message").font(.headline)
            TextField("To: phone number", text: $address)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send") {
                    onSend(address.trimmingCharacters(in: .whitespaces), text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.filter(\.isNumber).count < 3 || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
