import AppKit
import NearsideCore

/// Polls the general pasteboard (macOS has no change notification) and reports new text.
@MainActor
final class PasteboardWatcher: Clipboard {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private let onCopy: @MainActor (String) -> Void

    init(onCopy: @escaping @MainActor (String) -> Void) {
        self.onCopy = onCopy
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.1 // lets macOS fold it into other wake-ups
    }

    /// Writes text without reporting it back as a new copy.
    func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        // Password managers mark secrets as concealed or transient (nspasteboard.org convention).
        let types = pasteboard.types ?? []
        let skip = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        if types.contains(where: { skip.contains($0.rawValue) }) { return }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        onCopy(text)
    }
}
