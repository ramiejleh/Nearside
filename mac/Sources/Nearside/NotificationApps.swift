import NearsideCore
import SwiftUI

/// Settings → Notifications → Apps: a switch per phone app. A muted app's notifications never
/// reach this Mac (the phone doesn't send them); its calls still ring. Apps that have sent
/// notifications come first, then the rest of the phone's apps.
struct NotificationApps: View {
    let engine: SyncEngine
    @State private var expanded = false
    @State private var query = ""

    private struct Row: Identifiable {
        let id: String // the package
        let name: String
        let notified: Bool
    }

    private var rows: [Row] {
        var names: [String: String] = [:]
        for app in PhoneWindowManager.shared?.library.apps ?? [] where names[app.package] == nil { names[app.package] = app.label }
        for (package, name) in engine.notifyingApps { names[package] = names[package] ?? name }
        for package in engine.mutedApps where names[package] == nil { names[package] = package }
        let q = query.trimmingCharacters(in: .whitespaces)
        return names.map { Row(id: $0.key, name: $0.value, notified: engine.notifyingApps[$0.key] != nil) }
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q) }
            .sorted { ($0.notified ? 0 : 1, $0.name.lowercased()) < ($1.notified ? 0 : 1, $1.name.lowercased()) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            TextField("Search apps", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.vertical, 2)
            let rows = rows
            if rows.isEmpty {
                Text(query.isEmpty ? "Your phone's apps show here once it's connected." : "No app matches.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                Toggle(isOn: Binding(get: { !engine.mutedApps.contains(row.id) },
                                     set: { engine.setApp(row.id, muted: !$0) })) {
                    HStack(spacing: 8) {
                        icon(row.id)
                            .resizable()
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(row.name).lineLimit(1)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apps")
                Text(engine.mutedApps.isEmpty
                     ? "All apps' notifications show here. Turn one off to never see its notifications on this Mac."
                     : "\(engine.mutedApps.count) muted on this Mac. Their calls still ring.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .disabled(!engine.mirrorNotifications)
    }

    private func icon(_ package: String) -> Image {
        if let library = PhoneWindowManager.shared?.library, let app = library.app(package: package) {
            return Image(nsImage: library.icon(app))
        }
        if let url = PhoneNotification.iconURL(package: package), let image = NSImage(contentsOf: url) { return Image(nsImage: image) }
        return Image(systemName: "app.fill")
    }
}
