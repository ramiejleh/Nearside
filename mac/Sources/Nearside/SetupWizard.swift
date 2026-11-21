import NearsideCore
import ServiceManagement
import SwiftUI

/// First-run setup in its own window: the panel is a popover that closes whenever you click
/// elsewhere, which is most of the time during setup (you're busy on your phone).
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let engine: SyncEngine
    private var window: NSWindow?

    init(engine: SyncEngine) {
        self.engine = engine
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Set Up Nearside"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SetupWizard(engine: engine, close: { [weak window] in window?.close() }).tint(Theme.accent))
        window.center()
        return window
    }
}

struct SetupWizard: View {
    let engine: SyncEngine
    let close: () -> Void

    enum Page: Int, CaseIterable {
        case welcome, permissions, phone, pair, choices, done
    }

    @State private var page: Page

    init(engine: SyncEngine, close: @escaping () -> Void, startPage: Page = .welcome) {
        self.engine = engine
        self.close = close
        _page = State(initialValue: startPage)
    }
    @State private var permissions = Permissions()

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 34)
                .padding(.horizontal, 36)
            ScrollView {
                content
                    .padding(.horizontal, 36)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(page) // each page starts scrolled to the top
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(width: 620, height: 560)
        .animation(.snappy(duration: 0.25), value: page)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
        // Pairing ends with the phone connecting: move on by itself.
        .onChange(of: engine.state) { _, state in
            if page == .pair && state == .connected { page = .choices }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Group {
                if page == .welcome {
                    LogoTile(size: 56)
                } else {
                    // Later pages: their symbol on the logo's tile.
                    Image(systemName: icon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Color(nsColor: Logo.tileColor), in: RoundedRectangle(cornerRadius: 12.6, style: .continuous))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var icon: String {
        switch page {
        case .welcome: "link"
        case .permissions: "hand.raised"
        case .phone: "iphone.gen3.radiowaves.left.and.right"
        case .pair: "qrcode"
        case .choices: "slider.horizontal.3"
        case .done: "checkmark"
        }
    }

    private var title: String {
        switch page {
        case .welcome: "Welcome to Nearside"
        case .permissions: "Allow Nearside on this Mac"
        case .phone: "Prepare your phone"
        case .pair: "Pair with your phone"
        case .choices: "Choose what to sync"
        case .done: "You're all set"
        }
    }

    private var subtitle: String {
        switch page {
        case .welcome: "Your Android phone and this Mac, working together. A one-time setup of about two minutes."
        case .permissions: "macOS asks before an app uses these. Allow each one; you can change them later in Settings."
        case .phone: "Nearside connects through Android's Wireless debugging, which lives in Developer options."
        case .pair: "This links your phone and this Mac, once. It stays paired after reboots and Wi-Fi changes."
        case .choices: "You can change all of these later in Settings (the gear in the menu-bar panel)."
        case .done: "Nearside lives in your menu bar and works in the background."
        }
    }

    // MARK: Pages

    @ViewBuilder private var content: some View {
        switch page {
        case .welcome: welcome
        case .permissions: permissionsPage
        case .phone: phone
        case .pair: PairingView(engine: engine)
        case .choices: choices
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Feature(icon: "doc.on.clipboard", title: "Shared clipboard",
                    text: "Copy on one device, paste on the other. With a searchable history.")
            Feature(icon: "bell.badge", title: "Phone notifications",
                    text: "See, reply to and dismiss them on your Mac.")
            Feature(icon: "arrow.up.arrow.down.circle", title: "Files both ways",
                    text: "Drag files onto the menu-bar icon, or use Send to Mac from Android's share sheet.")
            Feature(icon: "message", title: "Text messages",
                    text: "Read and send SMS from a Messages window.")
            Label("You need an Android 11+ phone on the same Wi-Fi as this Mac. Nothing goes through the cloud.",
                  systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Permissions.kinds) { PermissionRow(permissions: permissions, kind: $0) }
            Label("Nothing leaves your Wi-Fi: these only let Nearside talk to your phone and show what it sends.",
                  systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var phone: some View {
        VStack(alignment: .leading, spacing: 14) {
            Instruction(number: 1, text: "On your phone, open **Settings → About phone** and tap **Build number** 7 times. This turns on Developer options. (Skip this if you already have them.)")
            Instruction(number: 2, text: "Open **Settings → System → Developer options** and turn on **Wireless debugging**.")
            Instruction(number: 3, text: "When asked, **allow** wireless debugging on this Wi-Fi network.")
            Label("Keep your phone and Mac on the same Wi-Fi. Wireless debugging stays on for that network after reboots.",
                  systemImage: "wifi")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Choice(title: "Mirror phone notifications",
                   text: "Your phone's notifications appear on this Mac. Dismiss, reply or click to open them on the phone.",
                   isOn: Binding(get: { engine.mirrorNotifications }, set: { engine.mirrorNotifications = $0 }))
            Choice(title: "Text messages",
                   text: "Read and send SMS from the Messages window. RCS chats stay in Google Messages.",
                   isOn: Binding(get: { engine.textMessages }, set: { engine.textMessages = $0 }))
            Choice(title: "Open at login",
                   text: "Start Nearside when you log in, so syncing is always on.",
                   isOn: Binding(get: { SMAppService.mainApp.status == .enabled },
                                 set: { on in _ = try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }))
            ClipboardToastChoice(engine: engine)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Feature(icon: "menubar.arrow.up.rectangle", title: "Click the phone icon in the menu bar",
                    text: "for your clipboard history, file transfers and settings. A number on it means new clips from your phone.")
            Feature(icon: "arrow.up.doc", title: "Drag files up to the menu bar",
                    text: "and a drop zone appears: drop to send them to your phone.")
            Feature(icon: "square.and.arrow.up", title: "On your phone, use Share → Send to Mac",
                    text: "to put photos and files in this Mac's Downloads.")
            Feature(icon: "message", title: "The speech bubble in the panel",
                    text: "opens your text messages.")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(visiblePages, id: \.self) { p in
                    Circle()
                        .fill(p == page ? Theme.accent : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if canGoBack {
                Button("Back") { page = previous }
                    .disabled(engine.isPairing)
            }
            primary
        }
        .controlSize(.large)
    }

    @ViewBuilder private var primary: some View {
        switch page {
        case .pair:
            // Advances by itself once the phone is connected.
            Button("Waiting for your phone…") {}
                .disabled(true)
        case .done:
            Button("Start Using Nearside") { close() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(AccentButtonStyle())
        case .permissions where !permissions.allAllowed:
            Button("Continue Without") { page = next } // not the Return key: skipping is a choice
        default:
            Button("Continue") { page = next }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(AccentButtonStyle())
        }
    }

    private var visiblePages: [Page] { Page.allCases }

    private var next: Page {
        let pages = visiblePages
        guard let i = pages.firstIndex(of: page), i + 1 < pages.count else { return page }
        return pages[i + 1]
    }

    private var previous: Page {
        let pages = visiblePages
        guard let i = pages.firstIndex(of: page), i > 0 else { return page }
        return pages[i - 1]
    }

    private var canGoBack: Bool {
        page != .welcome && page != .choices && page != .done // no going back past a finished pairing
    }
}

/// The explicit, informed choice about Android's clipboard toast (it's phone-wide).
private struct ClipboardToastChoice: View {
    let engine: SyncEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Choice(title: "Hide \u{201C}pasted from your clipboard\u{201D} messages",
                   text: "Android shows \u{201C}Shell pasted from your clipboard\u{201D} each time Nearside picks up something you copied. This is Android's own switch (Settings → Privacy → Show clipboard access) and it applies to every app: with it off, you also won't see when other apps read your clipboard.",
                   isOn: Binding(get: { engine.clipboardToastHidden ?? false },
                                 set: { engine.setClipboardToastHidden($0) }))
                .disabled(engine.clipboardToastHidden == nil)
        }
    }
}

private struct Feature: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Choice: View {
    let title: String
    let text: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(.green)
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
