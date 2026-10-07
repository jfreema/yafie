import AppKit

/// A brief message by the pointer, like "Text copied", that fades on its own. It never takes the focus, so ⌘V still
/// pastes in the app you're in.
@MainActor
enum Toast {
    private static let panel = makePanel()
    private static let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        return label
    }()
    private static var fading: Task<Void, Never>?

    /// Just above the point, kept on its screen
    static func show(_ message: String, near point: NSPoint) {
        label.stringValue = message
        label.sizeToFit()
        let size = NSSize(width: (label.frame.width + 32).rounded(), height: (label.frame.height + 16).rounded())
        label.setFrameOrigin(NSPoint(x: 16, y: ((size.height - label.frame.height) / 2).rounded()))
        let area = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(origin: point, size: size)
        let origin = NSPoint(x: min(max(point.x - size.width / 2, area.minX + 8), area.maxX - 8 - size.width),
                             y: min(max(point.y + 16, area.minY + 8), area.maxY - 8 - size.height))
        panel.setFrame(NSRect(origin: NSPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size), display: true)

        fading?.cancel()
        // Also stops a fade still running from the last one
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        fading = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: true)
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = .roundedMask(radius: 10)
        background.addSubview(label)
        panel.contentView = background
        return panel
    }
}

extension NSImage {
    /// For a borderless panel's NSVisualEffectView: rounds its corners, blur included
    static func roundedMask(radius: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 2 * radius + 1, height: 2 * radius + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
