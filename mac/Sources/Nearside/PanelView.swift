import NearsideCore
import SwiftUI

struct PanelView: View {
    let engine: SyncEngine
    /// Phone clips that were unseen when the panel opened; they keep their "New" tag while open.
    @State private var highlighted: Set<UUID> = []
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showingSettings {
                SettingsView(engine: engine, onDone: { showingSettings = false })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                Group {
                    switch engine.state {
                    case .adbMissing:
                        AdbMissingView()
                    case .needsSetup:
                        SetupView(engine: engine)
                    case .searching, .connected:
                        HistoryView(engine: engine, highlighted: highlighted)
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: showingSettings)
        .frame(width: 380, height: 540)
        // The panel is the app's only key window, so becoming key == the user opened it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            highlighted = engine.unseenIDs
            engine.markAllSeen()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(showingSettings ? "Settings" : "Nearside")
                .font(.system(size: 14, weight: .semibold))
                .contentTransition(.opacity)
            Spacer()
            StatusPill(state: engine.state, phoneName: engine.phoneName)
            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: showingSettings ? "xmark" : "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(showingSettings ? 0.08 : 0), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(showingSettings ? "Close settings" : "Settings")
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct StatusPill: View {
    let state: SyncEngine.State
    let phoneName: String

    var body: some View {
        let (color, text): (Color, String) = switch state {
        case .connected: (.green, phoneName)
        case .searching: (.orange, "Looking for \(phoneName)…")
        case .needsSetup: (.secondary, "Not set up")
        case .adbMissing: (.red, "adb missing")
        }
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(state == .connected ? 0.8 : 0), radius: 3)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .help(state == .searching ? "Make sure the phone is on the same Wi-Fi with Wireless debugging on." : "")
    }
}

struct AdbMissingView: View {
    private let command = "brew install --cask android-platform-tools"

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("One more tool needed")
                .font(.title3.weight(.semibold))
            Text("Nearside talks to your phone through Android's free adb tool. Install it in Terminal, then reopen Nearside.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Text(command)
                    .font(.system(size: 11.5, design: .monospaced))
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
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Button("Quit") { NSApp.terminate(nil) }
            Spacer()
        }
        .padding(24)
    }
}
