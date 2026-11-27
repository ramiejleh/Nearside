import NearsideCore
import NearsideMac
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
    @AppStorage("Panel.tab", store: PanelView.tabStore) private var tab = PanelTab.notifications.rawValue
    /// Pictures (NEARSIDE_TEST_DEMO) keep their tab apart, so taking them never changes yours.
    static let tabStore: UserDefaults = ProcessInfo.processInfo.environment["NEARSIDE_TEST_DEMO"] == "1"
        ? UserDefaults(suiteName: "dev.nearside.test") ?? .standard : .standard

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
                        if let problem = engine.phoneAppProblem {
                            PhoneAppProblemBanner(problem: problem, phoneName: engine.phoneName,
                                                  working: engine.reinstallingPhoneApp) { engine.reinstallPhoneApp() }
                        }
                        if engine.state == .connected {
                            if let until = engine.notificationsMutedUntil { MutedBanner(until: until) { engine.unmuteNotifications() } }
                            if engine.usbInUse { USBInUseBanner() }
                            if !engine.transfers.isEmpty { TransfersView(engine: engine) }
                            if engine.recentPhotos, !engine.photos.items.isEmpty {
                                PhotoStrip(engine: engine)
                                Divider()
                            }
                            // Only the features that are on (Settings → Features); tabs when both are.
                            switch (engine.mirrorNotifications, engine.clipboardSync) {
                            case (true, true):
                                PanelTabs(tab: $tab, notifications: engine.phoneNotifications.count, newClips: engine.unseenIDs.count)
                                if tab == PanelTab.clipboard.rawValue {
                                    HistoryView(engine: engine, highlighted: highlighted)
                                } else {
                                    PanelNotifications(engine: engine)
                                }
                            case (true, false): PanelNotifications(engine: engine)
                            case (false, true): HistoryView(engine: engine, highlighted: highlighted)
                            case (false, false): AllOff { showingSettings = true }
                            }
                        } else {
                            // Nothing of the phone's while it's away: only how to get it back.
                            PhoneAway(engine: engine)
                        }
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

    /// Two rows: who and how the phone is, then everything you can do.
    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                LogoTile(size: 26)
                Text("Nearside")
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize()
                Spacer(minLength: 8)
                if engine.mirrorNotifications, engine.state == .connected { MuteMenu(engine: engine) }
                StatusPill(state: engine.state, phoneName: engine.phoneName, inUseOn: engine.inUseOn, overUSB: engine.overUSB,
                           status: engine.state == .connected ? engine.phoneStatus : nil)
            }
            HStack(spacing: 6) {
                let connected = engine.state == .connected
                if connected {
                HeaderButton(title: "Apps", symbol: "apps.iphone", enabled: connected && !showingSettings,
                             help: "Open a phone app on your Mac", action: openApps)
                if engine.textMessages {
                    HeaderButton(title: "Messages", symbol: "message", enabled: !showingSettings,
                                 help: "Text messages", action: openMessages)
                }
                HeaderButton(title: "Send files", symbol: "paperplane", enabled: connected && !showingSettings,
                             help: "Send files to your \(engine.phoneName) (or drop them here)", action: chooseFiles)
                }
                HeaderButton(title: "Settings", symbol: showingSettings ? "xmark" : "gearshape", selected: showingSettings,
                             help: showingSettings ? "Close settings" : "Settings") { showingSettings.toggle() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

/// A button in the panel's second header row.
private struct HeaderButton: View {
    let title: String
    let symbol: String
    var enabled = true
    var selected = false
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(selected ? 0.14 : hovering && enabled ? 0.1 : 0.06),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
        .disabled(!enabled)
        .opacity(enabled || selected ? 1 : 0.45)
        .onHover { hovering = $0 }
        .help(help)
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
    var overUSB = false
    var status: PhoneStatus? = nil

    var body: some View {
        let (color, text): (Color, String) = switch state {
        case .connected: (.green, overUSB ? "\(phoneName) · USB" : phoneName)
        case .searching where inUseOn != nil: (.secondary, "In use on \(inUseOn ?? "")")
        case .searching: (.orange, "Looking for \(phoneName)…")
        case .needsSetup: (.secondary, "Not set up")
        }
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(state == .connected ? 0.8 : 0), radius: 3)
            Text(status != nil ? phoneName : text)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if let status {
                if overUSB {
                    Image(systemName: "cable.connector").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                PhoneStatusIcons(status: status)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .help(state == .searching ? "Make sure the phone is on the same Wi-Fi with Wireless debugging on, or plug it in with a USB cable."
              : status.map { "\(phoneName)\(overUSB ? ", connected by USB" : ""). \(PhoneStatusIcons.description($0))" } ?? "")
    }
}

/// The phone's signal and battery, as small as its own status bar shows them.
struct PhoneStatusIcons: View {
    let status: PhoneStatus

    var body: some View {
        HStack(spacing: 5) {
            if let bars = status.signal {
                HStack(spacing: 2) {
                    if let network = status.network {
                        Text(network).font(.system(size: 9.5, weight: .semibold))
                    }
                    Image(systemName: "cellularbars", variableValue: Double(bars) / 4)
                        .font(.system(size: 10.5))
                }
            }
            HStack(spacing: 2) {
                Image(systemName: Self.batterySymbol(status))
                    .font(.system(size: 12))
                    .foregroundStyle(status.battery <= PhoneStatus.LowBatteryAlert.threshold && !status.charging ? .red : .primary)
                Text("\(status.battery)%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.description(status))
    }

    static func batterySymbol(_ status: PhoneStatus) -> String {
        if status.charging { return "battery.100percent.bolt" }
        return switch status.battery {
        case 88...: "battery.100percent"
        case 63..<88: "battery.75percent"
        case 38..<63: "battery.50percent"
        case 13..<38: "battery.25percent"
        default: "battery.0percent"
        }
    }

    /// For the tooltip and VoiceOver: "Battery 82%, charging. 5G, 3 of 4 bars. On Wi-Fi."
    static func description(_ status: PhoneStatus) -> String {
        var parts = ["Battery \(status.battery)%\(status.charging ? ", charging" : "")."]
        if let bars = status.signal {
            parts.append("\(status.network.map { "\($0), " } ?? "")\(bars) of 4 bars.")
        }
        if status.wifi { parts.append("On Wi-Fi.") }
        return parts.joined(separator: " ")
    }
}

enum PanelTab: String { case notifications, clipboard }

/// Notifications and the clipboard both turned off: what's left, and where to turn them on.
private struct AllOff: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "switch.2").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
            Text("Notifications and the clipboard are off").font(.system(size: 13, weight: .semibold))
            Text("Turn them on in Settings → Features.").font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Open Settings", action: openSettings).controlSize(.small).padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Notifications | Clipboard, under the header: an icon and a count on each.
private struct PanelTabs: View {
    @Binding var tab: String
    let notifications: Int
    let newClips: Int

    var body: some View {
        SegmentedTabs(selection: $tab, segments: [
            .init(value: PanelTab.notifications.rawValue, title: "Notifications", symbol: "bell",
                  badge: notifications > 0 ? "\(notifications)" : nil),
            .init(value: PanelTab.clipboard.rawValue, title: "Clipboard", symbol: "doc.on.clipboard",
                  badge: newClips > 0 ? "\(newClips) new" : nil, accentBadge: true),
        ])
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// The panel's segmented control: the chosen segment raised on a sunk track. Used for the
/// panel's tabs and the clipboard's All | Phone | Mac, so both look the same.
struct SegmentedTabs<Value: Hashable>: View {
    struct Segment {
        let value: Value
        let title: String
        var symbol: String? = nil
        var badge: String? = nil
        var accentBadge = false
    }

    @Binding var selection: Value
    let segments: [Segment]
    /// Smaller type and padding, for a control beside a search field.
    var compact = false
    @Namespace private var namespace
    /// The chosen segment's fill: white on light, a lifted grey on dark (raised, not sunk).
    private static var raised: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.16) : .white
        })
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments.indices, id: \.self) { item(segments[$0]) }
        }
        .padding(compact ? 2 : 3)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous))
    }

    private func item(_ segment: Segment) -> some View {
        let selected = selection == segment.value
        return Button {
            withAnimation(.snappy(duration: 0.22)) { selection = segment.value }
        } label: {
            HStack(spacing: 6) {
                if let symbol = segment.symbol {
                    Image(systemName: selected ? "\(symbol).fill" : symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                }
                Text(segment.title).font(.system(size: compact ? 11.5 : 12.5, weight: selected ? .semibold : .medium))
                if let badge = segment.badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .foregroundStyle(segment.accentBadge ? Theme.onAccent : Color.secondary)
                        .background(segment.accentBadge ? Theme.accent : Color.primary.opacity(0.1), in: Capsule())
                }
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(maxWidth: compact ? nil : .infinity)
            .padding(.horizontal, compact ? 9 : 0)
            .padding(.vertical, compact ? 4 : 6)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: compact ? 6 : 7.5, style: .continuous)
                        .fill(Self.raised)
                        .shadow(color: .black.opacity(0.14), radius: 1.5, y: 0.5)
                        .matchedGeometryEffect(id: "selected", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(segment.badge.map { "\(segment.title), \($0)" } ?? segment.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The phone's current notifications: open one, use its buttons, reply, or dismiss it.
private struct PanelNotifications: View {
    let engine: SyncEngine

    var body: some View {
        if !engine.mirrorNotifications {
            empty("Phone notifications are off", "Turn them on to see your phone's notifications here.") {
                Button("Turn on") { engine.mirrorNotifications = true }.controlSize(.small)
            }
        } else if engine.phoneNotifications.isEmpty {
            empty("No notifications", "New ones from your \(engine.phoneName) show here.") { EmptyView() }
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(engine.phoneNotifications) { note in
                            NotificationCard(note: note, icon: icon(note.package), engine: engine) {
                                // As a click on the notification does: on the phone, or here (Settings).
                                let here = UserDefaults.standard.string(forKey: "PhoneApps.notificationClick") == "mac"
                                engine.openPhoneNotification(note, here: here)
                            }
                            .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                        }
                    }
                    .padding(12)
                    .animation(.easeOut(duration: 0.2), value: engine.phoneNotifications.map(\.key))
                }
                Divider()
                HStack {
                    Text(engine.phoneNotifications.count == 1 ? "1 notification" : "\(engine.phoneNotifications.count) notifications")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear All") { withAnimation(.easeOut(duration: 0.2)) { engine.clearPhoneNotifications() } }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }

    private func empty(_ title: String, _ detail: String, @ViewBuilder action: () -> some View) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "bell").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            action()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The app's launcher icon, else the one the phone sent with a notification (loaded once).
    private func icon(_ package: String) -> NSImage? { PhoneAppIcons.icon(package) }
}

/// The phone isn't connected: nothing of it shows, only where it is and how to get it back.
private struct PhoneAway: View {
    let engine: SyncEngine

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: engine.inUseOn != nil ? "laptopcomputer.and.arrow.down" : "iphone.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            if let other = engine.inUseOn {
                Text("\(engine.phoneName) is in use on \(other)").font(.system(size: 14, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("Connect to use it on this Mac instead.").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Connect") { engine.useHere() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            } else {
                Text("Looking for \(engine.phoneName)…").font(.system(size: 14, weight: .semibold))
                Text("Keep it nearby on the same Wi-Fi, or plug it in. It connects on its own.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// The bell beside the status: mute the phone's notifications for a while, or until turned back on.
private struct MuteMenu: View {
    let engine: SyncEngine

    var body: some View {
        let muted = engine.notificationsMutedUntil != nil
        Menu {
            if muted {
                Button("Turn notifications back on") { engine.unmuteNotifications() }
                Divider()
            }
            Section(muted ? "Mute instead" : "Mute notifications") {
                ForEach(NotificationSnooze.hours, id: \.self) { hours in
                    Button(hours == 1 ? "For 1 hour" : "For \(hours) hours") { engine.muteNotifications(hours: hours) }
                }
                Button("Until I turn them back on") { engine.muteNotifications(hours: nil) }
            }
        } label: {
            Image(systemName: muted ? "bell.slash.fill" : "bell")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(muted ? Color.orange : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(muted ? "Notifications from your phone are muted" : "Mute notifications from your phone")
        .accessibilityLabel(muted ? "Notifications muted" : "Mute notifications")
    }
}

/// Phone notifications are muted: until when, and a way to turn them back on.
/// Plugged in, but another program has the phone's USB connection: Nearside stays on Wi-Fi.
struct USBInUseBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cable.connector.slash")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("USB cable not in use").font(.system(size: 12.5, weight: .semibold))
                Text("Another program, such as adb or Android Studio, is using the phone's USB connection. Nearside stays on Wi-Fi and moves to the cable once it's free.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4))
    }
}

struct MutedBanner: View {
    let until: Date
    let unmute: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications muted").font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Turn on", action: unmute)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4))
    }

    private var detail: String {
        if until == .distantFuture { return "Until you turn them back on." }
        let sameDay = Calendar.current.isDate(until, inSameDayAs: Date())
        let time = until.formatted(sameDay ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute())
        return "Until \(time). What arrives meanwhile shows then."
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
                .foregroundStyle(Theme.accent)
            Text("Connect your Android phone")
                .font(.title3.weight(.semibold))
            Text("A one-time setup of about two minutes. Afterwards everything syncs on its own.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button("Set Up Nearside…", action: openSetup)
                .buttonStyle(AccentButtonStyle())
                .controlSize(.large)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
