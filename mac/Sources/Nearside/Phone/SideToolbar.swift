import AppKit

/// The vertical toolbar beside a phone app or the phone window (never over it), the same in
/// every window at every size: navigation at the top, then the toolbox (sizes, crop, Open on
/// Phone). A macOS toolbar folded its items into a "»" menu when the window was narrow.
@MainActor
final class SideToolbar: NSView {
    static let width: CGFloat = 44

    enum Entry {
        case button(id: String, symbol: String, label: String, action: () -> Void)
        case separator
        /// Pushes what follows to the bottom.
        case spacer
    }

    /// Its empty parts drag the window (the phone window has no title bar).
    var dragsWindow = false

    private var buttons: [String: ToolButton] = [:]
    private var actions: [String: () -> Void] = [:]

    init(_ entries: [Entry]) {
        super.init(frame: .zero)
        let effect = NSVisualEffectView()
        effect.material = .titlebar
        effect.blendingMode = .withinWindow
        effect.state = .followsWindowActiveState
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let edge = NSBox()
        edge.boxType = .separator
        edge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edge)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor), effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor), effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: leadingAnchor), edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor), edge.widthAnchor.constraint(equalToConstant: 1),
        ])
        for entry in entries {
            switch entry {
            case let .button(id, symbol, label, action):
                let button = ToolButton(symbol: symbol, label: label)
                button.target = self
                button.action = #selector(pressed(_:))
                button.identifier = NSUserInterfaceItemIdentifier(id)
                buttons[id] = button
                actions[id] = action
                stack.addArrangedSubview(button)
            case .separator:
                let line = NSBox()
                line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                line.widthAnchor.constraint(equalToConstant: 24).isActive = true
                stack.addArrangedSubview(line)
                stack.setCustomSpacing(8, after: stack.arrangedSubviews[max(stack.arrangedSubviews.count - 2, 0)])
                stack.setCustomSpacing(8, after: line)
            case .spacer:
                let spacer = NSView()
                spacer.setContentHuggingPriority(.init(1), for: .vertical)
                stack.addArrangedSubview(spacer)
            }
        }
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Phone app tools")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A size or a toggle shown as chosen.
    func setSelected(_ id: String, _ selected: Bool) { buttons[id]?.chosen = selected }

    func setSymbol(_ id: String, _ symbol: String, label: String) { buttons[id]?.set(symbol: symbol, label: label) }

    func setEnabled(_ id: String, _ enabled: Bool) { buttons[id]?.isEnabled = enabled }

    func setHidden(_ id: String, _ hidden: Bool) { buttons[id]?.isHidden = hidden }

    @objc private func pressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        actions[id]?()
    }

    override func mouseDown(with event: NSEvent) {
        if dragsWindow { window?.performDrag(with: event) } else { super.mouseDown(with: event) }
    }
}

/// A square icon button with a hover highlight; "chosen" (a size in use, a toggle on) is tinted.
private final class ToolButton: NSButton {
    var chosen = false { didSet { update() } }
    private var hovering = false { didSet { update() } }

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        set(symbol: symbol, label: label)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(symbol: String, label: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        toolTip = label
        setAccessibilityLabel(label)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.35 } }

    private func update() {
        contentTintColor = chosen ? .controlAccentColor : .secondaryLabelColor
        layer?.backgroundColor = chosen ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            : hovering ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : nil
        setAccessibilityValue(chosen ? "selected" : nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }
}
