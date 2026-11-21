import AppKit
import Network
import Observation
import SwiftUI
import UserNotifications

/// The macOS permissions Nearside needs, their current state, and a way to ask for each.
/// Watched (refreshed every second) while a view showing them is on screen.
@MainActor
@Observable
final class Permissions {
    enum Kind: CaseIterable, Identifiable {
        case localNetwork, notifications, clipboard
        var id: Self { self }
    }

    /// The kinds this macOS has (the clipboard permission exists from macOS 15.4).
    static var kinds: [Kind] { pasteAccess == .none ? [.localNetwork, .notifications] : Kind.allCases }

    /// "Paste from Other Apps" (NSPasteboard.accessBehavior, macOS 15.4+).
    enum PasteAccess { case none, notAsked, ask, allow, deny }
    static var pasteAccess: PasteAccess {
        guard #available(macOS 15.4, *) else { return .none }
        return switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: .allow
        case .alwaysDeny: .deny
        case .ask: .ask
        default: .notAsked
        }
    }

    enum Status {
        case checking
        case allowed
        /// Not asked yet (or the system's answer isn't known): the button asks.
        case needed
        /// Turned off: only System Settings can turn it on.
        case denied
    }

    private(set) var status: [Kind: Status] = [.localNetwork: .checking, .notifications: .checking, .clipboard: .checking]
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watchers = 0

    func startWatching() {
        watchers += 1
        guard watchers == 1 else { return }
        startBrowser()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
        browser?.cancel()
        browser = nil
    }

    var allAllowed: Bool { Self.kinds.allSatisfy { status[$0] == .allowed } }

    // MARK: Asking

    func request(_ kind: Kind) {
        switch (kind, status[kind]) {
        case (_, .denied?):
            openSettings(kind)
        case (.localNetwork, _):
            // Any Bonjour search makes macOS ask; if it already said no, only Settings helps.
            startBrowser()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if self?.status[.localNetwork] != .allowed { self?.openSettings(.localNetwork) }
            }
        case (.notifications, _):
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        case (.clipboard, _):
            if Self.pasteAccess == .notAsked {
                // Reading the clipboard once brings up the system's question.
                _ = NSPasteboard.general.string(forType: .string)
            } else {
                openSettings(.clipboard) // "Ask" prompts on every copy: Always Allow lives in Settings
            }
        }
    }

    func openSettings(_ kind: Kind) {
        let url = switch kind {
        case .localNetwork: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        case .notifications: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "dev.nearside.mac")"
        case .clipboard: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard"
        }
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    // MARK: Checking

    private func refresh() {
        status[.clipboard] = switch Self.pasteAccess {
        case .none, .allow: .allowed
        case .deny: .denied
        case .notAsked, .ask: .needed // asks on access: a background sync would alert on every copy
        }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status: Status = switch settings.authorizationStatus {
            case .authorized, .provisional: .allowed
            case .denied: .denied
            default: .needed
            }
            Task { @MainActor in self?.status[.notifications] = status }
        }
    }

    /// macOS has no API for the local-network permission: a Bonjour search for the phone's
    /// service tells. Ready = allowed; waiting with "policy denied" = not (yet) allowed.
    private func startBrowser() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_adb-tls-connect._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            let status: Status? = switch state {
            case .ready: .allowed
            case .waiting(let error), .failed(let error):
                if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { .needed } else { nil }
            default: nil
            }
            guard let status else { return }
            MainActor.assumeIsolated { self?.status[.localNetwork] = status } // started on .main
        }
        browser.start(queue: .main)
        self.browser = browser
    }
}

/// One permission: what it's for, its state, and the button that asks for it.
struct PermissionRow: View {
    let permissions: Permissions
    let kind: Permissions.Kind

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.green)
                .frame(width: 30, height: 30)
                .background(Color.green.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var control: some View {
        switch permissions.status[kind] ?? .checking {
        case .checking:
            ProgressView().controlSize(.small)
        case .allowed:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
                .font(.callout.weight(.medium))
        case .needed:
            Button(buttonTitle) { permissions.request(kind) }
                .controlSize(.regular)
        case .denied:
            Button("Open Settings…") { permissions.openSettings(kind) }
                .controlSize(.regular)
        }
    }

    private var icon: String {
        switch kind {
        case .localNetwork: "wifi"
        case .notifications: "bell.badge"
        case .clipboard: "doc.on.clipboard"
        }
    }

    private var title: String {
        switch kind {
        case .localNetwork: "Local Network"
        case .notifications: "Notifications"
        case .clipboard: "Paste from Other Apps"
        }
    }

    private var detail: String {
        switch (kind, permissions.status[kind]) {
        case (.localNetwork, _):
            "Finds your phone on this Wi-Fi and connects to it. Needed for everything."
        case (.notifications, .denied?):
            "Turned off: your phone's notifications can't appear. Turn on Allow Notifications in Settings."
        case (.notifications, _):
            "Shows your phone's notifications and arriving files on this Mac."
        case (.clipboard, _) where Permissions.pasteAccess == .ask:
            "macOS asks each time Nearside reads what you copied. Set Nearside to Always Allow in Settings."
        case (.clipboard, .allowed?):
            "Sends what you copy on this Mac to your phone without asking every time."
        case (.clipboard, _):
            "Sends what you copy on this Mac to your phone without asking every time. Choose Always Allow."
        }
    }

    private var buttonTitle: String {
        if kind == .clipboard, Permissions.pasteAccess == .ask { return "Open Settings…" }
        return "Allow…"
    }
}
