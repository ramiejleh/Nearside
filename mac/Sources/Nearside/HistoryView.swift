import NearsideCore
import SwiftUI

struct HistoryView: View {
    let engine: SyncEngine
    let highlighted: Set<UUID>

    private enum Filter: String, CaseIterable {
        case all = "All", phone = "Phone", mac = "Mac"
        var source: ClipItem.Source? {
            switch self {
            case .all: nil
            case .phone: .android
            case .mac: .mac
            }
        }
    }

    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var confirmClear = false

    var body: some View {
        let items = engine.history.filtered(query: query, source: filter.source)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    TextField("Search history", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if items.isEmpty {
                EmptyHistory(isFiltering: !query.isEmpty || filter != .all, phoneName: engine.phoneName)
            } else {
                // Re-render every 30 s so relative times ("2m") stay fresh.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(items) { item in
                                HistoryRow(item: item,
                                           phoneName: engine.phoneName,
                                           isNew: highlighted.contains(item.id),
                                           now: context.date,
                                           onUse: { engine.use(item) },
                                           onDelete: {
                                               withAnimation(.easeOut(duration: 0.2)) { engine.delete(item) }
                                           })
                                .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .trailing))))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
            }

            Divider()
            footer
        }
    }

    @ViewBuilder private var footer: some View {
        let count = engine.history.items.count
        HStack(spacing: 8) {
            if confirmClear {
                Text("Delete all \(footerText(count: count))?")
                    .foregroundStyle(.primary)
                Spacer()
                Button("Cancel") { confirmClear = false }
                    .buttonStyle(.borderless)
                Button("Clear All") {
                    withAnimation(.easeOut(duration: 0.2)) { engine.clearHistory() }
                    confirmClear = false
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .fontWeight(.semibold)
            } else {
                Text(footerText(count: count))
                Text("·").foregroundStyle(.tertiary)
                Text("Click to copy to both devices")
                    .lineLimit(1)
                Spacer()
                Button {
                    confirmClear = true
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(count == 0)
                .help("Delete all saved items")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .animation(.easeOut(duration: 0.15), value: confirmClear)
    }

    private func footerText(count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}

struct HistoryRow: View {
    let item: ClipItem
    let phoneName: String
    let isNew: Bool
    let now: Date
    let onUse: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var justCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SourceBadge(source: item.source)
            VStack(alignment: .leading, spacing: 4) {
                Text(preview)
                    .font(.system(size: 12.5))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    if isNew {
                        Text("NEW")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.green, in: Capsule())
                    }
                    Text(meta)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            // Always laid out (just invisible when not hovered) so the text never reflows.
            HStack(spacing: 2) {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowIconButtonStyle(hoverColor: .red))
                .help("Delete")
                .opacity(hovering && !justCopied ? 1 : 0)
                .allowsHitTesting(hovering && !justCopied)

                ZStack {
                    if justCopied {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Button(action: use) {
                            Image(systemName: "doc.on.doc")
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(RowIconButtonStyle(hoverColor: .accentColor))
                        .help("Copy to Mac and phone")
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(background)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture { use() }
        .contextMenu {
            Button("Copy to Mac and Phone") { use() }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(item.text.count > 400 ? String(item.text.prefix(400)) + "…" : item.text)
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if isNew {
            shape.fill(Color.green.opacity(hovering ? 0.16 : 0.10))
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.green).frame(width: 3).padding(.vertical, 8)
                }
        } else {
            shape.fill(Color.primary.opacity(hovering ? 0.06 : 0))
        }
    }

    private func use() {
        onUse()
        withAnimation(.spring(duration: 0.25)) { justCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.2)) { justCopied = false }
        }
    }

    /// Whitespace-trimmed, with runs of blank lines collapsed so previews stay dense.
    private var preview: String {
        item.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n\\s*\n+", with: "\n", options: .regularExpression)
    }

    private var meta: String {
        let source = item.source == .android ? phoneName : "This Mac"
        let size = item.text.count == 1 ? "1 char" : "\(item.text.count.formatted()) chars"
        return "\(source) · \(RelativeTime.string(for: item.date, now: now)) · \(size)"
    }
}

/// Small icon button inside a row: secondary colour, tinted while hovered.
private struct RowIconButtonStyle: ButtonStyle {
    let hoverColor: Color
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? hoverColor : .secondary)
            .background(hoverColor.opacity(hovering ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 5))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onHover { hovering = $0 }
    }
}

struct SourceBadge: View {
    let source: ClipItem.Source

    var body: some View {
        let color: Color = source == .android ? .green : .blue
        Image(systemName: source == .android ? "smartphone" : "laptopcomputer")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(color.opacity(0.15), in: Circle())
    }
}

struct EmptyHistory: View {
    let isFiltering: Bool
    let phoneName: String

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: isFiltering ? "magnifyingglass" : "doc.on.clipboard")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(isFiltering ? "No matches" : "Nothing copied yet")
                .font(.headline)
            Text(isFiltering ? "Try a different search or filter."
                             : "Copy something on your \(phoneName) or this Mac and it appears here, on both clipboards.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

enum RelativeTime {
    static func string(for date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        default:
            if Calendar.current.isDateInYesterday(date) { return "yesterday" }
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
