import AppKit

/// The on/off switch in a menu row. In a menu, NSSwitch draws as if its window were inactive, gray even when on, so
/// this one draws itself: the accent color when on. Same size and shape as a small NSSwitch.
@MainActor
final class MenuSwitch: NSView {
    var isOn = false {
        didSet { needsDisplay = true }
    }

    var isEnabled = true {
        didSet { needsDisplay = true }
    }

    /// When VoiceOver flips it. Clicks go to the row.
    var onPress: (() -> Void)?

    private static let track = NSSize(width: 32, height: 18)
    private static let knobInset: CGFloat = 1

    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 21) }

    // The row takes the clicks, so the label flips it too
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let track = NSRect(x: (bounds.width - Self.track.width) / 2, y: (bounds.height - Self.track.height) / 2,
                           width: Self.track.width, height: Self.track.height)
        let diameter = track.height - 2 * Self.knobInset
        let knob = NSRect(x: isOn ? track.maxX - Self.knobInset - diameter : track.minX + Self.knobInset,
                          y: track.minY + Self.knobInset, width: diameter, height: diameter)

        // Faded as a whole when disabled
        context.setAlpha(isEnabled ? 1 : 0.4)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        (isOn ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
        context.endTransparencyLayer()
    }

    // A switch to VoiceOver, labeled by the row

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .switch }
    override func accessibilityValue() -> Any? { NSNumber(value: isOn) }
    override func isAccessibilityEnabled() -> Bool { isEnabled }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        isOn.toggle()
        onPress?()
        return true
    }
}
