import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A snip as taken: its pixels, and their scale, 2 from a Retina display
struct Snip {
    let image: CGImage
    let scale: CGFloat
    let taken: Date

    init(image: CGImage, scale: CGFloat, taken: Date = Date()) {
        self.image = image
        self.scale = scale
        self.taken = taken
    }

    /// From a PNG, taking the scale from the dpi screencapture recorded (144 on a Retina display)
    init?(data: Data, taken: Date = Date()) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = properties?[kCGImagePropertyDPIWidth] as? Double ?? 72
        self.init(image: image, scale: max(1, (dpi / 72).rounded()), taken: taken)
    }

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    /// As it was on screen, in points
    var size: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }

    /// "Snip 2026-10-04 at 14.32.05", like macOS's own screenshot names, in 24-hour time
    var name: String { Self.name(for: taken) }

    static func name(for date: Date, in timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "'Snip' yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}

/// One shape on a snip, in the snip's pixels: origin at the top left, y down
struct Annotation: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case box, line, arrow, highlight, text }

    enum Color: String, CaseIterable, Sendable {
        case red, green, blue, yellow

        /// Fixed sRGB values, so the saved file matches the editor in light and dark mode
        var cgColor: CGColor {
            switch self {
            case .red: CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
            case .green: CGColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)
            case .blue: CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
            case .yellow: CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)
            }
        }

        /// Around text, so it stands out on dark snips and light ones: black around yellow, white around the rest
        var outline: CGColor { self == .yellow ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1) }
    }

    enum Thickness: String, CaseIterable, Sendable {
        case thin, thick

        /// Line width, in points
        var width: CGFloat { self == .thin ? 2 : 5 }
        /// Arrowhead length, in points. A thick head is shorter for its width, so it doesn't swamp the arrow.
        var headLength: CGFloat { self == .thin ? 10 : 18 }
        /// Text size, in points
        var textSize: CGFloat { self == .thin ? 16 : 24 }
        /// The outline around text, as a percentage of its size. It's centered on the letters' edges, so half of it
        /// shows. Thin enough to set the letters off without taking them over.
        var textOutline: CGFloat { self == .thin ? 3 : 6 }
    }

    struct Head: Equatable {
        var tip: CGPoint
        var left: CGPoint
        var right: CGPoint
        /// Where the shaft stops, inside the head so the tip stays sharp. Nil when the head is the whole arrow.
        var shaftEnd: CGPoint?
    }

    /// How much of the color a highlight lays down. Multiply, a real marker's look, barely shows on dark-mode
    /// screenshots, so highlights are plain translucent color.
    static let highlightOpacity: CGFloat = 0.4

    var kind: Kind
    var color: Color
    /// Line width, or text size. A highlight is filled.
    var thickness: Thickness
    /// A text's top left
    var start: CGPoint
    var end: CGPoint
    var text = ""

    /// A box's or highlight's rectangle
    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Shift: lines and arrows at multiples of 45°, boxes and highlights square
    static func constrained(_ kind: Kind, from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        switch kind {
        case .box, .highlight:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        case .text:
            return end
        case .line, .arrow:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            // Projected onto that direction, so a nearly level drag keeps its length
            let length = dx * cos(angle) + dy * sin(angle)
            return CGPoint(x: start.x + length * cos(angle), y: start.y + length * sin(angle))
        }
    }

    /// A triangle 0.9 times as wide as it's long, shrunk to fit a shorter arrow
    static func head(from start: CGPoint, to end: CGPoint, length full: CGFloat) -> Head? {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        let headLength = min(full, length)
        let halfWidth = 0.45 * headLength
        let (ux, uy) = (dx / length, dy / length)
        let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
        let middle = CGPoint(x: end.x - ux * headLength / 2, y: end.y - uy * headLength / 2)
        return Head(tip: end,
                    left: CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth),
                    right: CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth),
                    shaftEnd: length > headLength ? middle : nil)
    }
}

enum SnipRenderer {
    /// Draws the shapes into a context whose units are the snip's pixels, origin at the top left. The editor's canvas
    /// and the export both use this, so what's saved is what was on screen.
    /// - Parameter scale: the snip's pixels per point, 2 from a Retina display
    static func draw(_ annotations: [Annotation], in context: CGContext, scale: CGFloat) {
        // Highlights first, so they tint the snip but never the other shapes
        for highlight in annotations where highlight.kind == .highlight {
            let color = highlight.color.cgColor
            context.setFillColor(color.copy(alpha: Annotation.highlightOpacity) ?? color)
            context.fill(highlight.rect)
        }
        for annotation in annotations where annotation.kind != .highlight {
            context.setStrokeColor(annotation.color.cgColor)
            context.setFillColor(annotation.color.cgColor)
            context.setLineWidth(annotation.thickness.width * scale)
            context.setLineCap(.round)
            context.setLineJoin(.miter)
            let (start, end) = (annotation.start, annotation.end)
            switch annotation.kind {
            case .box:
                context.stroke(annotation.rect)
            case .line:
                context.strokeLineSegments(between: [start, end])
            case .arrow:
                guard let head = Annotation.head(from: start, to: end, length: annotation.thickness.headLength * scale)
                else { continue }
                if let shaftEnd = head.shaftEnd { context.strokeLineSegments(between: [start, shaftEnd]) }
                context.addLines(between: [head.tip, head.left, head.right])
                context.closePath()
                context.fillPath()
            case .text:
                drawText(annotation, in: context, scale: scale)
            case .highlight:
                break
            }
        }
    }

    /// Bold, in the color, with an outline behind it, its top left at the start point
    private static func drawText(_ annotation: Annotation, in context: CGContext, scale: CGFloat) {
        let font = textFont(annotation.thickness, scale: scale)
        func line(_ attributes: [CFString: Any]) -> CTLine {
            var all = attributes
            all[kCTFontAttributeName] = font
            let keyed = Dictionary(uniqueKeysWithValues: all.map { (NSAttributedString.Key($0.key as String), $0.value) })
            return CTLineCreateWithAttributedString(NSAttributedString(string: annotation.text, attributes: keyed))
        }
        // The outline, then the letters over it
        let outline = line([kCTStrokeWidthAttributeName: annotation.thickness.textOutline,
                            kCTStrokeColorAttributeName: annotation.color.outline])
        let fill = line([kCTForegroundColorAttributeName: annotation.color.cgColor])
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // upright, since y runs down
        context.setLineJoin(.round)
        let baseline = CGPoint(x: annotation.start.x, y: annotation.start.y + CTFontGetAscent(font))
        for line in [outline, fill] {
            context.textPosition = baseline
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    /// The system font in bold, in the snip's pixels
    static func textFont(_ thickness: Annotation.Thickness, scale: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, thickness.textSize * scale, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, thickness.textSize * scale, nil)
    }

    /// The snip with its shapes at full resolution, in the snip's own color space so nothing shifts
    static func render(_ snip: CGImage, _ annotations: [Annotation], scale: CGFloat) -> CGImage? {
        let space = snip.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: snip.width, height: snip.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let height = CGFloat(snip.height)
        context.draw(snip, in: CGRect(x: 0, y: 0, width: CGFloat(snip.width), height: height))
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        draw(annotations, in: context, scale: scale)
        return context.makeImage()
    }

    /// A PNG, or a TIFF for the clipboard, that keeps the dpi, so apps that read it show the snip at its on-screen size
    static func data(_ image: CGImage, scale: CGFloat, type: UTType = .png) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
        if type == .tiff { properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] }  // LZW
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Where the editor shows a snip: at actual size, or smaller to fit, centered. In the canvas's points, origin at the
/// top left.
struct SnipFit: Equatable {
    let frame: CGRect
    /// Snip pixels per canvas point
    let pixelsPerPoint: CGFloat

    init(_ pixels: CGSize, scale: CGFloat, in canvas: CGSize) {
        let natural = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        let fit = canvas.width > 0 && canvas.height > 0
            ? min(1, canvas.width / natural.width, canvas.height / natural.height) : 1
        let size = CGSize(width: natural.width * fit, height: natural.height * fit)
        frame = CGRect(x: ((canvas.width - size.width) / 2).rounded(.down),
                       y: ((canvas.height - size.height) / 2).rounded(.down), width: size.width, height: size.height)
        pixelsPerPoint = scale / fit
    }

    /// A point on the canvas in snip pixels, kept on the snip
    func pixel(for point: CGPoint) -> CGPoint {
        let x = min(max(point.x, frame.minX), frame.maxX), y = min(max(point.y, frame.minY), frame.maxY)
        return CGPoint(x: (x - frame.minX) * pixelsPerPoint, y: (y - frame.minY) * pixelsPerPoint)
    }

    func point(for pixel: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX + pixel.x / pixelsPerPoint, y: frame.minY + pixel.y / pixelsPerPoint)
    }
}

/// The editor window's measurements, in points
enum SnipEditorLayout {
    static let toolbarHeight: CGFloat = 44
    /// Room for the whole toolbar
    static let minimumWidth: CGFloat = 600
    static let minimumCanvasHeight: CGFloat = 120

    /// The window's content size for a snip: actual size under the toolbar, shrunk to fit 90% of the display's
    /// visible area, and never narrower than the toolbar
    static func contentSize(for snip: CGSize, on visible: CGRect) -> CGSize {
        let room = CGSize(width: visible.width * 0.9, height: visible.height * 0.9 - toolbarHeight)
        let fit = min(1, room.width / snip.width, room.height / snip.height)
        return CGSize(width: max((snip.width * fit).rounded(), minimumWidth),
                      height: max((snip.height * fit).rounded(), minimumCanvasHeight) + toolbarHeight)
    }
}
