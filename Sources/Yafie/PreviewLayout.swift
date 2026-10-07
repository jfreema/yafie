import CoreGraphics

/// Where App Preview's panel and its cards go. Pure geometry in AppKit coordinates: origin at the bottom left of the
/// main display, y up.
enum PreviewLayout {
    /// The side of the screen the Dock is on
    enum Edge: Sendable {
        case bottom, left, right

        /// From the Dock's "orientation" setting, which is missing while it's at the bottom
        init(orientation: String?) {
            self = switch orientation {
            case "left": .left
            case "right": .right
            default: .bottom
            }
        }
    }

    struct Placement: Equatable {
        /// On the screen
        var panel: CGRect
        /// Inside the panel, one per window in order: in rows from the top left above a bottom Dock, in columns
        /// from the top beside a side one
        var cards: [CGRect]
    }

    /// A window's picture at full size, 16:10
    static let picture = CGSize(width: 240, height: 150)
    /// Around a card's picture and title
    static let padding: CGFloat = 8
    static let titleHeight: CGFloat = 16
    static let titleGap: CGFloat = 4
    /// Between cards, and between them and the panel's edge
    static let spacing: CGFloat = 8
    /// Between the icon and the panel
    static let gap: CGFloat = 8
    /// The closest the panel comes to the screen's edges
    static let margin: CGFloat = 8
    /// How far the pointer can stray from the icon, panel and the way between them before the panel closes
    static let slack: CGFloat = 10
    /// The smallest cards get, to fit many windows
    static let smallest: CGFloat = 0.4

    /// The panel beside the icon, centered on it and kept on the screen. Cards shrink when too many windows would
    /// leave the screen, down to `smallest`.
    /// - Parameter area: the screen's visible frame, without the menu bar
    static func place(_ count: Int, by icon: CGRect, edge: Edge, in area: CGRect) -> Placement {
        let count = max(count, 1)
        // Along the Dock, and away from it
        let room: (along: CGFloat, away: CGFloat) = switch edge {
        case .bottom: (area.width - 2 * margin, area.maxY - margin - icon.maxY - gap)
        case .left: (area.height - 2 * margin, area.maxX - margin - icon.maxX - gap)
        case .right: (area.height - 2 * margin, icon.minX - gap - area.minX - margin)
        }
        var scale: CGFloat = 1
        var card = cardSize(scale: scale)
        var perLine = 1
        while true {
            let length = edge == .bottom ? card.width : card.height
            let depth = edge == .bottom ? card.height : card.width
            perLine = max(1, Int(((room.along - spacing) / (length + spacing)).rounded(.down)))
            let lines = (count + perLine - 1) / perLine
            if CGFloat(lines) * (depth + spacing) + spacing <= room.away || scale <= smallest { break }
            scale = max(smallest, scale - 0.1)
            card = cardSize(scale: scale)
        }

        let lines = (count + perLine - 1) / perLine
        let (columns, rows) = edge == .bottom ? (min(count, perLine), lines) : (lines, min(count, perLine))
        let size = CGSize(width: CGFloat(columns) * (card.width + spacing) + spacing,
                          height: CGFloat(rows) * (card.height + spacing) + spacing)
        let origin = switch edge {
        case .bottom:
            CGPoint(x: clamp(icon.midX - size.width / 2, area.minX + margin, area.maxX - margin - size.width),
                    y: icon.maxY + gap)
        case .left:
            CGPoint(x: icon.maxX + gap,
                    y: clamp(icon.midY - size.height / 2, area.minY + margin, area.maxY - margin - size.height))
        case .right:
            CGPoint(x: icon.minX - gap - size.width,
                    y: clamp(icon.midY - size.height / 2, area.minY + margin, area.maxY - margin - size.height))
        }
        let panel = CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)

        let cards = (0..<count).map { index in
            let (line, step) = (index / perLine, index % perLine)
            let (column, row) = edge == .bottom ? (step, line) : (line, step)
            // Beside a side Dock, the first column is the one nearest it
            let x = edge == .right
                ? size.width - CGFloat(column + 1) * (card.width + spacing)
                : spacing + CGFloat(column) * (card.width + spacing)
            let y = size.height - CGFloat(row + 1) * (card.height + spacing)
            return CGRect(origin: CGPoint(x: x, y: y), size: card)
        }
        return Placement(panel: panel, cards: cards)
    }

    /// The icon at the Dock's largest size, since the Dock may still be magnifying it. It grows away from the edge.
    static func magnified(_ icon: CGRect, to largest: CGFloat, edge: Edge) -> CGRect {
        switch edge {
        case .bottom: CGRect(x: icon.minX, y: icon.minY, width: icon.width, height: max(icon.height, largest))
        case .left: CGRect(x: icon.minX, y: icon.minY, width: max(icon.width, largest), height: icon.height)
        case .right:
            CGRect(x: icon.maxX - max(icon.width, largest), y: icon.minY, width: max(icon.width, largest),
                   height: icon.height)
        }
    }

    static func cardSize(scale: CGFloat) -> CGSize {
        CGSize(width: (picture.width * scale).rounded() + 2 * padding,
               height: (picture.height * scale).rounded() + titleGap + titleHeight + 2 * padding)
    }

    /// Where the picture goes in a card, above its title
    static func pictureArea(in card: CGSize) -> CGRect {
        let bottom = padding + titleHeight + titleGap
        return CGRect(x: padding, y: bottom, width: card.width - 2 * padding, height: card.height - bottom - padding)
    }

    static func titleArea(in card: CGSize) -> CGRect {
        CGRect(x: padding, y: padding, width: card.width - 2 * padding, height: titleHeight)
    }

    static let closeButtonSize: CGFloat = 20

    /// The × that closes a window, in its picture's top right corner
    static func closeButton(on picture: CGRect) -> CGRect {
        CGRect(x: picture.maxX - closeButtonSize - 4, y: picture.maxY - closeButtonSize - 4, width: closeButtonSize,
               height: closeButtonSize)
    }

    /// The largest rect with the size's shape that fits in the area, centered in it, in whole points
    static func fit(_ size: CGSize, in area: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return area }
        let scale = min(area.width / size.width, area.height / size.height)
        let width = (size.width * scale).rounded(), height = (size.height * scale).rounded()
        return CGRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(),
                      width: width, height: height)
    }

    /// Whether the pointer is still on its way between the icon and the panel, or on either
    static func keepsOpen(_ point: CGPoint, panel: CGRect, icon: CGRect, edge: Edge) -> Bool {
        let both = panel.union(icon)
        let between = switch edge {
        case .bottom: CGRect(x: both.minX, y: icon.maxY, width: both.width, height: max(0, panel.minY - icon.maxY))
        case .left: CGRect(x: icon.maxX, y: both.minY, width: max(0, panel.minX - icon.maxX), height: both.height)
        case .right: CGRect(x: panel.maxX, y: both.minY, width: max(0, icon.minX - panel.maxX), height: both.height)
        }
        return [panel, icon, between].contains { $0.insetBy(dx: -slack, dy: -slack).contains(point) }
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        // A panel wider than the screen starts at its left
        max(low, min(value, high))
    }
}
