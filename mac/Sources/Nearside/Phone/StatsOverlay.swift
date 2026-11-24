import NearsideCore
import NearsideMac
import AppKit

/// View → Show Statistics: a small readout over a phone window's picture, once a second:
/// frames arriving and shown, bitrate, the phone-to-Mac delay, encode time and ping.
@MainActor
final class StatsOverlay: NSView {
    static let key = "PhoneApps.stats"
    static let changed = Notification.Name("PhoneAppsStatsChanged")

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    private let label = NSTextField(labelWithString: "")
    private weak var session: PhoneAppSession?
    private let renderer: MetalRenderer
    private var timer: Timer?

    init(session: PhoneAppSession, renderer: MetalRenderer) {
        self.session = session
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer?.cornerRadius = 6
        label.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        setAccessibilityLabel("Statistics")
        NotificationCenter.default.addObserver(self, selector: #selector(apply), name: Self.changed, object: nil)
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Not in the way of the app: clicks go through.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func apply() {
        isHidden = !Self.enabled
        renderer.countsPresented = Self.enabled
        timer?.invalidate()
        timer = nil
        guard Self.enabled else { return }
        _ = session?.takeStats() // start a fresh second
        _ = renderer.takePresented()
        label.stringValue = "…"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func update() {
        guard let stats = session?.takeStats() else { return }
        let shown = Double(renderer.takePresented()) / max(stats.seconds, 0.001)
        let delay = stats.latencyMs.map { "\($0.average) ms (worst \($0.worst))" } ?? "–"
        let buffer = renderer.smooth ? String(format: " · buffer %.0f ms", renderer.pacer.addedDelay * 1000) : ""
        label.stringValue = String(format: "%.0f fps in · %.0f shown\n%.1f Mbps\ndelay %@%@\nencode %d ms · ping %d ms",
                                   stats.fps, shown, stats.mbps, delay, buffer, stats.encodeMs, Int(stats.rttMicros / 1000))
        Trace.log("stats: " + label.stringValue.replacingOccurrences(of: "\n", with: " | "))
    }

    /// The window closed: no more updates.
    func stop() {
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate()
        timer = nil
    }
}
