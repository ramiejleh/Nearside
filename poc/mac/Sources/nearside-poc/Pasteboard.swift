import AppKit

/// Polls the general pasteboard (macOS has no change notification) and reports new text.
final class PasteboardWatcher {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private let onCopy: (String) -> Void

    init(onCopy: @escaping (String) -> Void) {
        self.onCopy = onCopy
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// Writes text that came from the phone without echoing it back.
    func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        // Password managers mark secrets as concealed (nspasteboard.org convention).
        let types = pasteboard.types ?? []
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) { return }
        guard let text = pasteboard.string(forType: .string) else { return }
        onCopy(text)
    }
}
