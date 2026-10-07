import AppKit

/// App Preview's panel: a card for each of an app's windows, beside its Dock icon. It floats over everything, the
/// Dock included, and never takes the focus from the app you're in.
@MainActor
final class PreviewPanel {
    struct Card {
        var title: String
        /// The window's size, whose shape the picture keeps
        var size: CGSize
        var picture: CGImage?
        var isMinimized: Bool
        /// Shows a × that closes the window
        var canClose: Bool
    }

    /// Called with the card's index when it's clicked
    var onChoose: ((Int) -> Void)?
    /// Called with the card's index when its × is clicked
    var onClose: ((Int) -> Void)?

    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
    private let background = NSVisualEffectView()
    private var cards: [CardView] = []

    var isVisible: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }

    init() {
        panel.level = .popUpMenu  // over the Dock
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        // On every desktop and over full-screen apps, like the Dock, and never in ⌘Tab or Mission Control
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = .roundedMask(radius: 12)
        panel.contentView = background
    }

    func show(_ cards: [Card], icon: NSImage?, placement: PreviewLayout.Placement) {
        for view in self.cards { view.removeFromSuperview() }
        self.cards = zip(cards, placement.cards).enumerated().map { index, pair in
            let view = CardView(pair.0, icon: icon, frame: pair.1)
            view.onClick = { [weak self] in self?.onChoose?(index) }
            view.onClose = { [weak self] in self?.onClose?(index) }
            background.addSubview(view)
            return view
        }
        panel.setFrame(placement.panel, display: true)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func setPicture(_ picture: CGImage, at index: Int) {
        guard cards.indices.contains(index) else { return }
        cards[index].picture = picture
    }

    func hide() {
        panel.orderOut(nil)
        for view in cards { view.removeFromSuperview() }
        cards = []
    }
}

/// One window: its picture, or the app's icon until there is one, over its title, with a × to close it. It lights up
/// under the pointer, and takes the first click even though Yafie isn't the active app.
private final class CardView: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var picture: CGImage? {
        didSet { layoutPicture() }
    }

    private let card: PreviewPanel.Card
    private let icon: NSImage?
    private let imageView = NSImageView()
    private let title: NSTextField
    private let closeButton = CloseButton()
    /// The window's shape, drawn behind the icon while there's no picture
    private var placeholder: CGRect?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(_ card: PreviewPanel.Card, icon: NSImage?, frame: CGRect) {
        self.card = card
        self.icon = icon
        title = NSTextField(labelWithString: card.title)
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 12)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.textColor = card.isMinimized ? .secondaryLabelColor : .labelColor
        title.frame = PreviewLayout.titleArea(in: frame.size)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.alphaValue = card.isMinimized ? 0.5 : 1
        addSubview(imageView)
        addSubview(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(card.isMinimized ? "\(card.title), minimized" : card.title)
        if card.canClose {
            closeButton.onPress = { [weak self] in self?.onClose?() }
            addSubview(closeButton)  // over the picture
            setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Close Window") { [weak self] in
                self?.onClose?()
                return true
            }])
        }
        picture = card.picture
        layoutPicture()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    private func layoutPicture() {
        let shape = PreviewLayout.fit(card.size, in: PreviewLayout.pictureArea(in: bounds.size))
        if let picture {
            placeholder = nil
            imageView.image = NSImage(cgImage: picture, size: shape.size)
            imageView.frame = shape
            imageView.layer?.cornerRadius = 4
            imageView.layer?.masksToBounds = true
        } else {
            placeholder = shape
            let side = min(64, shape.width * 0.6, shape.height * 0.6).rounded()
            imageView.image = icon
            imageView.frame = CGRect(x: (shape.midX - side / 2).rounded(), y: (shape.midY - side / 2).rounded(),
                                     width: side, height: side)
            imageView.layer?.cornerRadius = 0
        }
        closeButton.frame = PreviewLayout.closeButton(on: shape)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        if let placeholder {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: placeholder, xRadius: 4, yRadius: 4).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    // Clicks anywhere on the card land on the card, not its picture or title, except on its ×
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        let inside = convert(point, from: superview)
        return closeButton.superview != nil && closeButton.frame.contains(inside) ? closeButton : self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}  // claim the click, so mouseUp comes here

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// The × in a card's corner. White on a dark circle, which shows on light pictures and dark ones, and red under the
/// pointer.
private final class CloseButton: NSView {
    var onPress: (() -> Void)?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = isHovered ? NSColor.systemRed : NSColor.black.withAlphaComponent(0.6)
        let configuration = NSImage.SymbolConfiguration(pointSize: bounds.height, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, circle]))
        NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)?
            .draw(in: bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}  // claim the click, so mouseUp comes here

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }
}
