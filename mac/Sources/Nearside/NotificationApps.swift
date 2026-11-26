import NearsideCore
import SwiftUI

/// Phone apps' icons, loaded once each: the launcher's when it has the app, else the one the
/// phone sent with a notification. Notification cards and the Apps page redraw often; reading
/// a file each time made the panel sluggish.
@MainActor
enum PhoneAppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ package: String) -> NSImage? {
        if let library = PhoneWindowManager.shared?.library, let app = library.app(package: package) { return library.icon(app) }
        if let image = cache[package] { return image }
        // Not there yet is checked again next time (cheap): a notification may bring it.
        guard let url = PhoneNotification.iconURL(package: package), let image = NSImage(contentsOf: url) else { return nil }
        cache[package] = image
        return image
    }
}

/// Settings → Notifications → Apps, a row that opens `NotificationAppsPage`.
struct NotificationAppsRow: View {
    let engine: SyncEngine
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apps")
                    Text(engine.mutedApps.isEmpty
                         ? "Choose which apps' notifications show on this Mac."
                         : "\(engine.mutedApps.count) muted on this Mac. Their calls still ring.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A switch per phone app (built only while open). A muted app's notifications never reach this
/// Mac: the phone doesn't send them. Its calls still ring. Apps that have sent notifications come
/// first, then the rest of the phone's apps.
struct NotificationAppsPage: View {
    let engine: SyncEngine
    let onBack: () -> Void
    @State private var query = ""
    @State private var all: [Row] = []

    struct Row: Identifiable, Equatable {
        let id: String // the package
        let name: String
        let notified: Bool
    }

    private var shown: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Label("Settings", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 4) {
                Text("Notifications from apps").font(.system(size: 15, weight: .semibold))
                Text("Turn an app off and its notifications never come to this Mac. Its calls still ring.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            TextField("Search apps", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()
            let rows = shown
            if rows.isEmpty {
                Text(query.isEmpty ? "Your phone's apps show here once it's connected." : "No app matches.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    section("Have sent notifications", rows.filter(\.notified))
                    section("Other apps", rows.filter { !$0.notified })
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [Row]) -> some View {
        if !rows.isEmpty {
            // Headings as plain rows: a List's section header pins with a rule under it.
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            ForEach(rows) { row in
                AppRow(row: row, muted: engine.mutedApps.contains(row.id)) { on in
                    engine.setApp(row.id, muted: !on)
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            }
        }
    }

    /// The list, made once when the page opens (the engine's other changes don't rebuild it).
    private func load() {
        var names: [String: String] = [:]
        for app in PhoneWindowManager.shared?.library.apps ?? [] where names[app.package] == nil { names[app.package] = app.label }
        for (package, name) in engine.notifyingApps { names[package] = names[package] ?? name }
        for package in engine.mutedApps where names[package] == nil { names[package] = package }
        all = names.map { Row(id: $0.key, name: $0.value, notified: engine.notifyingApps[$0.key] != nil) }
            .sorted { ($0.notified ? 0 : 1, $0.name.lowercased()) < ($1.notified ? 0 : 1, $1.name.lowercased()) }
    }

    private struct AppRow: View {
        let row: Row
        let muted: Bool
        let set: (Bool) -> Void

        var body: some View {
            HStack(spacing: 10) {
                Group {
                    if let icon = PhoneAppIcons.icon(row.id) {
                        Image(nsImage: icon).resizable()
                    } else {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.1))
                    }
                }
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(row.name).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { !muted }, set: set))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(.green)
                    .accessibilityLabel("Notifications from \(row.name)")
            }
            .padding(.vertical, 3)
        }
    }
}
