/// Arrow-key movement through the launcher: sections of icons (Recents, Favourites, All Apps),
/// each laid out in rows of `columns`, as one flat list of positions.
public struct LauncherGrid: Equatable, Sendable {
    public enum Move: Sendable { case left, right, up, down }

    public let sections: [Int]
    public let columns: Int

    public init(sections: [Int], columns: Int) {
        self.sections = sections
        self.columns = max(columns, 1)
    }

    public var count: Int { sections.reduce(0, +) }

    /// (section, index in it) of flat position `i`.
    func place(_ i: Int) -> (section: Int, index: Int) {
        var rest = i
        for (s, n) in sections.enumerated() {
            if rest < n { return (s, rest) }
            rest -= n
        }
        return (sections.count - 1, max((sections.last ?? 1) - 1, 0))
    }

    func start(of section: Int) -> Int { sections.prefix(section).reduce(0, +) }

    /// Where `move` from `i` lands. Left/right run on through the whole list; up/down keep the
    /// column, crossing into the section above or below (its last or first row), and stay put at
    /// the very top or bottom.
    public func moving(_ i: Int, _ move: Move) -> Int {
        guard count > 0 else { return 0 }
        let i = min(max(i, 0), count - 1)
        switch move {
        case .left: return max(i - 1, 0)
        case .right: return min(i + 1, count - 1)
        case .down, .up:
            let (s, index) = place(i)
            let column = index % columns
            let row = index / columns
            if move == .down {
                if (row + 1) * columns < sections[s] { return start(of: s) + min(index + columns, sections[s] - 1) }
                guard let next = sections.indices.dropFirst(s + 1).first(where: { sections[$0] > 0 }) else { return i }
                return start(of: next) + min(column, sections[next] - 1)
            }
            if row > 0 { return start(of: s) + index - columns }
            guard let prev = sections.indices.prefix(s).last(where: { sections[$0] > 0 }) else { return i }
            let lastRow = (sections[prev] - 1) / columns
            return start(of: prev) + min(lastRow * columns + column, sections[prev] - 1)
        }
    }
}
