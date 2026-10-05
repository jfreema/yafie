import AppKit

/// Menu row with an on/off switch, like Control Center's
@MainActor
final class ToggleRow: NSView {
    // Lines up with macOS 26's menu titles, indent levels and shortcuts.
    // A label's text sits 2 points inside its frame, as the titles' does.
    private static let textInset: CGFloat = 16
    private static let indentStep: CGFloat = 12
    private static let switchInset: CGFloat = 10

    private let label: NSTextField
    private let toggle = MenuSwitch()
    private let onChange: (Bool) -> Void

    var isOn: Bool {
        get { toggle.isOn }
        set { toggle.isOn = newValue }
    }

    var isEnabled = true {
        didSet {
            toggle.isEnabled = isEnabled
            label.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        }
    }

    init(_ title: String, indented: Bool = false, onChange: @escaping (Bool) -> Void) {
        label = NSTextField(labelWithString: title)
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 28))
        // Stretches to the menu's width
        autoresizingMask = .width

        label.font = .menuFont(ofSize: 0)
        label.setAccessibilityElement(false)  // the switch carries the title
        toggle.onPress = { [weak self] in self?.onChange(self?.isOn ?? false) }
        toggle.setAccessibilityLabel(title)
        for view in [label, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset + (indented ? Self.indentStep : 0)),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 16),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.switchInset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        frame.size.width = fittingSize.width
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    // Clicks anywhere land on the row, so the label flips the switch too
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === label ? self : hit
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? { toggle }

    override func mouseDown(with event: NSEvent) {}  // claim the click, so mouseUp comes here

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        isOn.toggle()
        onChange(isOn)
    }
}
