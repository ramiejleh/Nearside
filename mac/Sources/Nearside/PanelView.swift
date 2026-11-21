import NearsideCore
import SwiftUI

struct PanelView: View {
    let engine: SyncEngine
    let openMessages: () -> Void
    let openSetup: () -> Void
    let openApps: () -> Void
    /// Phone clips that were unseen when the panel opened; they keep their "New" tag while open.
    @State private var highlighted: Set<UUID> = []
    @State private var showingSettings = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showingSettings {
                SettingsView(engine: engine, onDone: { showingSettings = false }, openSetup: openSetup)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                Group {
                    switch engine.state {
                    case .needsSetup:
                        SetupPrompt(openSetup: openSetup)
                    case .searching, .connected:
                        if let other = engine.inUseOn, engine.state != .connected { InUseElsewhere(phoneName: engine.phoneName, other: other) { engine.useHere() } }
                        if let problem = engine.phoneAppProblem {
                            PhoneAppProblemBanner(problem: problem, phoneName: engine.phoneName,
                                                  working: engine.reinstallingPhoneApp) { engine.reinstallPhoneApp() }
                        }
                        if !engine.transfers.isEmpty { TransfersView(engine: engine) }
                        HistoryView(engine: engine, highlighted: highlighted)
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: showingSettings)
        .animation(.snappy(duration: 0.25), value: engine.transfers.count)
        // Drop files anywhere on the panel to send them to the phone.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard engine.state == .connected else { return false }
            loadURLs(providers) { engine.sendFiles($0) }
            return true
        }
        .overlay {
            if dropTargeted {
                DropOverlay(phoneName: engine.phoneName, connected: engine.state == .connected)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .frame(width: 380, height: 540)
        // The panel is the app's only key window, so becoming key == the user opened it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            highlighted = engine.unseenIDs
            engine.markAllSeen()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            LogoTile(size: 26)
            Text(showingSettings ? "Settings" : "Nearside")
                .font(.system(size: 14, weight: .semibold))
                .contentTransition(.opacity)
            Spacer()
            StatusPill(state: engine.state, phoneName: engine.phoneName, inUseOn: engine.inUseOn)
            if engine.state == .connected && !showingSettings {
                Button(action: openApps) {
                    Image(systemName: "apps.iphone")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open a phone app on your Mac")
            }
            if (engine.state == .connected || engine.state == .searching) && !showingSettings {
                Button(action: openMessages) {
                    Image(systemName: "message")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Text messages")
            }
            if engine.state == .connected && !showingSettings {
                Button(action: chooseFiles) {
                    Image(systemName: "paperplane")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Send files to your \(engine.phoneName) (or drop them here)")
            }
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

extension PanelView {
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Send"
        panel.message = "Choose files to send to your \(engine.phoneName)"
        NSApp.activate()
        panel.begin { response in
            if response == .OK { engine.sendFiles(panel.urls) }
        }
    }

    private func loadURLs(_ providers: [NSItemProvider], then send: @escaping @MainActor ([URL]) -> Void) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await withCheckedContinuation({ (done: CheckedContinuation<URL?, Never>) in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
                }) { urls.append(url) }
            }
            if !urls.isEmpty { send(urls) }
        }
    }
}

private struct DropOverlay: View {
    let phoneName: String
    let connected: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundStyle(connected ? Color.green : Color.secondary)
                .padding(14)
            VStack(spacing: 10) {
                Image(systemName: connected ? "arrow.up.doc.on.clipboard" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(connected ? Color.green : Color.secondary)
                Text(connected ? "Drop to send to your \(phoneName)" : "\(phoneName) isn't connected")
                    .font(.headline)
                if connected {
                    Text("Files land in Download/Nearside on the phone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct StatusPill: View {
    let state: SyncEngine.State
    let phoneName: String
    var inUseOn: String? = nil

    var body: some View {
        let (color, text): (Color, String) = switch state {
        case .connected: (.green, phoneName)
        case .searching where inUseOn != nil: (.secondary, "In use on \(inUseOn ?? "")")
        case .searching: (.orange, "Looking for \(phoneName)…")
        case .needsSetup: (.secondary, "Not set up")
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

/// Another Mac took the phone: this one waits (it checks now and then) or takes it back.
struct InUseElsewhere: View {
    let phoneName: String
    let other: String
    let useHere: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer.and.arrow.down")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(phoneName) is in use on \(other)").font(.system(size: 12.5, weight: .semibold))
                Text("This Mac reconnects once it's free.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Use on this Mac", action: useHere)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4))
    }
}

/// The phone app couldn't be updated to the one in this Mac app.
struct PhoneAppProblemBanner: View {
    let problem: SyncEngine.PhoneAppProblem
    let phoneName: String
    let working: Bool
    let reinstall: () -> Void
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nearside on \(phoneName) needs updating").font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if case .otherSignature = problem {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Reinstall…") { confirming = true }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4))
        .confirmationDialog("Reinstall Nearside on \(phoneName)?", isPresented: $confirming) {
            Button("Reinstall", action: reinstall)
        } message: {
            Text("The phone app is removed and installed again. Its permissions are set up again automatically; nothing on your Mac changes.")
        }
    }

    private var detail: String {
        switch problem {
        case .otherSignature: "It was installed from a different build, so it can't be updated in place."
        case .failed(let message): "The update didn't work: \(message) It's tried again next time Nearside starts."
        }
    }
}

/// Shown in the panel until a phone is set up; the setup itself is a separate window.
struct SetupPrompt: View {
    let openSetup: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.green)
            Text("Connect your Android phone")
                .font(.title3.weight(.semibold))
            Text("A one-time setup of about two minutes. Afterwards everything syncs on its own.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button("Set Up Nearside…", action: openSetup)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
