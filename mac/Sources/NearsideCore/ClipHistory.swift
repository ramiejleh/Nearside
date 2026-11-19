import Foundation

public struct ClipItem: Codable, Identifiable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case mac
        case android
    }

    public let id: UUID
    public let text: String
    public let source: Source
    public var date: Date

    public init(id: UUID = UUID(), text: String, source: Source, date: Date = Date()) {
        self.id = id
        self.text = text
        self.source = source
        self.date = date
    }
}

/// Newest-first clipboard history. Copying the same text again moves it to the top instead of
/// duplicating it. Pure value type so it is easy to test; persistence is explicit.
public struct ClipHistory: Equatable, Sendable {
    public private(set) var items: [ClipItem]
    public var limit: Int {
        didSet { trim() }
    }

    public init(items: [ClipItem] = [], limit: Int = 200) {
        self.items = items
        self.limit = max(1, limit)
        trim()
    }

    @discardableResult
    public mutating func add(_ text: String, source: ClipItem.Source, date: Date = Date()) -> ClipItem {
        items.removeAll { $0.text == text }
        let item = ClipItem(text: text, source: source, date: date)
        items.insert(item, at: 0)
        trim()
        return item
    }

    /// Moves an existing item to the top (it was just re-used).
    public mutating func promote(id: UUID, date: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.date = date
        items.insert(item, at: 0)
    }

    public mutating func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    public mutating func clear() {
        items.removeAll()
    }

    /// Case-insensitive search, optionally limited to one source.
    public func filtered(query: String, source: ClipItem.Source?) -> [ClipItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            (source == nil || item.source == source)
                && (query.isEmpty || item.text.localizedCaseInsensitiveContains(query))
        }
    }

    private mutating func trim() {
        if items.count > limit { items.removeLast(items.count - limit) }
    }

    // MARK: Persistence

    /// Clipboard history is sensitive: the file is written atomically and readable by the owner only.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(items)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(from url: URL, limit: Int) -> ClipHistory {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([ClipItem].self, from: data) else {
            return ClipHistory(limit: limit)
        }
        return ClipHistory(items: items, limit: limit)
    }
}
