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
        window.contentView = NSHostingView(rootView: SetupWizard(engine: engine, close: { [weak window] in window?.close() }))
        window.center()
        return window
    }
}

struct SetupWizard: View {
    let engine: SyncEngine
    let close: () -> Void

    enum Page: Int, CaseIterable {
        case welcome, adb, phone, pair, choices, done
    }

    @State private var page: Page = .welcome
    @State private var adbStillMissing = false
    @State private var downloading = false
    @State private var downloadProgress = 0.0
    @State private var downloadError: String?

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
        // Pairing ends with the phone connecting: move on by itself.
        .onChange(of: engine.state) { _, state in
            if page == .pair && state == .connected { page = .choices }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentTransition(.symbolEffect(.replace))
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
        case .adb: "shippingbox"
        case .phone: "iphone.gen3.radiowaves.left.and.right"
        case .pair: "qrcode"
        case .choices: "slider.horizontal.3"
        case .done: "checkmark"
        }
    }

    private var title: String {
        switch page {
        case .welcome: "Welcome to Nearside"
        case .adb: "One tool to download"
        case .phone: "Prepare your phone"
        case .pair: "Pair with your phone"
        case .choices: "Choose what to sync"
        case .done: "You're all set"
        }
    }

    private var subtitle: String {
        switch page {
        case .welcome: "Your Android phone and this Mac, working together. A one-time setup of about two minutes."
        case .adb: "Nearside talks to your phone through adb, Android's free connection tool from Google."
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
        case .adb: adb
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

    private var adb: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("**Download adb** fetches Google's official platform-tools (about 17 MB) and keeps them in Nearside's own folder. Nearside only uses it if it's signed by Google.")
                    .fixedSize(horizontal: false, vertical: true)
                if downloading {
                    ProgressView(value: downloadProgress) {
                        Text(downloadProgress < 1 ? "Downloading from Google…" : "Checking Google's signature…")
                            .font(.callout)
                    }
                }
                if let downloadError {
                    Label(downloadError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("By downloading you accept Google's [Android SDK terms](https://developer.android.com/studio/terms).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            DisclosureGroup("Or install it yourself") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("With Homebrew in Terminal, then click **Check Again**:")
                    CommandBox(command: "brew install --cask android-platform-tools")
                    HStack {
                        Button("Check Again") {
                            if engine.recheckAdb() { adbStillMissing = false; page = .phone } else { adbStillMissing = true }
                        }
                        if adbStillMissing {
                            Text("Still not found.").foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
    }

    private func downloadAdb() {
        downloading = true
        downloadError = nil
        downloadProgress = 0
        Task {
            let result = await AdbInstaller.install { value in
                Task { @MainActor in downloadProgress = value }
            }
            downloading = false
            switch result {
            case .success:
                if engine.recheckAdb() { page = .phone } else { downloadError = AdbInstaller.Failure.missingAdb.message }
            case .failure(let failure):
                downloadError = failure.message
            }
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
                        .fill(p == page ? Color.green : Color.secondary.opacity(0.3))
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
        case .adb:
            Button(downloading ? "Downloading…" : "Download adb", action: downloadAdb)
                .keyboardShortcut(.defaultAction)
                .tint(.green)
                .buttonStyle(.borderedProminent)
                .disabled(downloading)
        case .pair:
            // Advances by itself once the phone is connected.
            Button("Waiting for your phone…") {}
                .disabled(true)
        case .done:
            Button("Start Using Nearside") { close() }
                .keyboardShortcut(.defaultAction)
                .tint(.green)
                .buttonStyle(.borderedProminent)
        default:
            Button("Continue") { page = next }
                .keyboardShortcut(.defaultAction)
                .tint(.green)
                .buttonStyle(.borderedProminent)
        }
    }

    /// The adb page only exists when adb is missing.
    private var visiblePages: [Page] {
        Page.allCases.filter { $0 != .adb || Adb.path == nil || page == .adb }
    }

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
                .foregroundStyle(.green)
                .frame(width: 34, height: 34)
                .background(Color.green.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct CommandBox: View {
    let command: String

    var body: some View {
        HStack {
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy command")
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
