import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
@testable import Yafie

struct AnnotationTests {
    @Test func shiftLevelsANearlyLevelLineAndKeepsItsLength() {
        let end = Annotation.constrained(.line, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 14))
        #expect(abs(end.x - 110) < 1e-9)
        #expect(abs(end.y - 10) < 1e-9)
    }

    @Test func shiftSnaps30DegreesTo45() {
        let thirty = CGFloat.pi / 6
        let end = Annotation.constrained(.arrow, from: .zero, to: CGPoint(x: 100 * cos(thirty), y: 100 * sin(thirty)))
        #expect(end.x > 0)
        #expect(abs(end.x - end.y) < 1e-9)
    }

    @Test(arguments: zip([1.0, -1, 1, -1], [1.0, 1, -1, -1]))
    func shiftMakesBoxesAndHighlightsSquare(signX: CGFloat, signY: CGFloat) {
        for kind in [Annotation.Kind.box, .highlight] {
            let end = Annotation.constrained(kind, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50 + 30 * signX, y: 50 + 80 * signY))
            #expect(end == CGPoint(x: 50 + 80 * signX, y: 50 + 80 * signY))
        }
    }

    @Test func arrowheadTipIsTheEndAndItsBaseIsSquareToTheShaft() {
        let length: CGFloat = 20
        let head = Annotation.head(from: .zero, to: CGPoint(x: 300, y: 400), length: length)!
        #expect(head.tip == CGPoint(x: 300, y: 400))
        let base = CGPoint(x: (head.left.x + head.right.x) / 2, y: (head.left.y + head.right.y) / 2)
        #expect(abs(hypot(head.tip.x - base.x, head.tip.y - base.y) - length) < 1e-9)
        // The shaft runs along (0.6, 0.8)
        #expect(abs((head.left.x - head.right.x) * 0.6 + (head.left.y - head.right.y) * 0.8) < 1e-9)
        #expect(abs(hypot(head.left.x - head.right.x, head.left.y - head.right.y) - 0.9 * length) < 1e-9)
        #expect(head.shaftEnd != nil)
    }

    @Test func thickArrowheadsAreShorterForTheirWidth() {
        #expect(Annotation.Thickness.thin.headLength == 10)
        #expect(Annotation.Thickness.thin.headLength == 5 * Annotation.Thickness.thin.width)
        #expect(Annotation.Thickness.thick.headLength == 18)
        #expect(Annotation.Thickness.thick.headLength < 5 * Annotation.Thickness.thick.width)
    }

    @Test func aShortArrowGetsASmallerHeadAndNoShaft() {
        let head = Annotation.head(from: .zero, to: CGPoint(x: 8, y: 0), length: 20)!
        #expect(head.left.x == 0)
        #expect(head.shaftEnd == nil)
    }

    @Test func aZeroLengthArrowDrawsNothing() {
        #expect(Annotation.head(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5), length: 20) == nil)
    }
}

struct SnipRendererTests {
    @Test func drawsTheBoxWhereItIsAndLeavesTheRestAlone() {
        let snip = SnipImages.plain()
        let box = Annotation(kind: .box, color: .red, thickness: .thick, start: CGPoint(x: 100, y: 50),
                             end: CGPoint(x: 300, y: 250))
        let image = SnipRenderer.render(snip, [box], scale: 2)!
        #expect(image.width == 400 && image.height == 300)
        #expect(SnipImages.isRed(SnipImages.pixel(image, 100, 150)))
        #expect(SnipImages.isRed(SnipImages.pixel(image, 200, 50)))
        #expect(SnipImages.pixel(image, 200, 150) == SnipImages.pixel(snip, 200, 150))
        #expect(SnipImages.pixel(image, 20, 20) == SnipImages.pixel(snip, 20, 20))
    }

    @Test func aHighlightTintsWithoutCovering() {
        let snip = SnipImages.plain()
        let highlight = Annotation(kind: .highlight, color: .yellow, thickness: .thin, start: CGPoint(x: 100, y: 50),
                                   end: CGPoint(x: 300, y: 250))
        let image = SnipRenderer.render(snip, [highlight], scale: 2)!
        // 40% of the way from the gray to yellow, so the gray still shows through
        let inside = SnipImages.pixel(image, 200, 150), gray = SnipImages.pixel(snip, 200, 150)
        #expect(abs(inside[0] - (0.4 * 1 + 0.6 * gray[0])) < 0.03)
        #expect(abs(inside[1] - (0.4 * 0.8 + 0.6 * gray[1])) < 0.03)
        #expect(inside[2] < gray[2])
        #expect(SnipImages.pixel(image, 20, 20) == SnipImages.pixel(snip, 20, 20))
    }

    @Test func highlightsGoUnderTheOtherShapes() {
        let box = Annotation(kind: .box, color: .red, thickness: .thick, start: CGPoint(x: 100, y: 50),
                             end: CGPoint(x: 300, y: 250))
        let highlight = Annotation(kind: .highlight, color: .yellow, thickness: .thin, start: CGPoint(x: 50, y: 100),
                                   end: CGPoint(x: 350, y: 200))
        let image = SnipRenderer.render(SnipImages.plain(), [box, highlight], scale: 2)!
        #expect(SnipImages.isRed(SnipImages.pixel(image, 100, 150)))
    }

    @Test func thicknessDoesntChangeAHighlight() {
        let thin = Annotation(kind: .highlight, color: .green, thickness: .thin, start: CGPoint(x: 100, y: 50),
                              end: CGPoint(x: 300, y: 250))
        var thick = thin
        thick.thickness = .thick
        let a = SnipRenderer.render(SnipImages.plain(), [thin], scale: 2)!
        let b = SnipRenderer.render(SnipImages.plain(), [thick], scale: 2)!
        for (x, y) in [(99, 150), (100, 150), (200, 150), (300, 150), (301, 150)] {
            #expect(SnipImages.pixel(a, x, y) == SnipImages.pixel(b, x, y))
        }
    }

    @Test func outlinesGoAroundLinesAndBoxes() {
        let isWhite: ([Double]) -> Bool = { $0.allSatisfy { $0 > 0.95 } }
        let isBlack: ([Double]) -> Bool = { $0.allSatisfy { $0 < 0.05 } }
        var line = Annotation(kind: .line, color: .red, thickness: .thin, start: CGPoint(x: 100, y: 50),
                              end: CGPoint(x: 100, y: 250), outline: .white)
        let outlined = SnipRenderer.render(SnipImages.plain(), [line], scale: 2)!
        // 1.5 points a side at 2 pixels a point, around the 4-pixel line
        let row = (80..<120).map { SnipImages.pixel(outlined, $0, 150) }
        #expect(row.filter(SnipImages.isRed).count == 4)
        #expect(row.filter(isWhite).count == 6)
        line.outline = .none
        let plain = SnipRenderer.render(SnipImages.plain(), [line], scale: 2)!
        #expect((80..<120).filter { isWhite(SnipImages.pixel(plain, $0, 150)) }.isEmpty)

        // Inside and outside a thick box's 10-pixel edge
        let box = Annotation(kind: .box, color: .red, thickness: .thick, start: CGPoint(x: 100, y: 50),
                             end: CGPoint(x: 300, y: 250), outline: .black)
        let image = SnipRenderer.render(SnipImages.plain(), [box], scale: 2)!
        #expect(isBlack(SnipImages.pixel(image, 93, 150)) && isBlack(SnipImages.pixel(image, 106, 150)))
        #expect(SnipImages.isRed(SnipImages.pixel(image, 100, 150)))
    }

    @Test func highlightsHaveNoOutline() {
        var highlight = Annotation(kind: .highlight, color: .yellow, thickness: .thin, start: CGPoint(x: 100, y: 50),
                                   end: CGPoint(x: 300, y: 250))
        let plain = SnipRenderer.render(SnipImages.plain(), [highlight], scale: 2)!
        highlight.outline = .black
        let outlined = SnipRenderer.render(SnipImages.plain(), [highlight], scale: 2)!
        for (x, y) in [(96, 150), (99, 150), (100, 150), (200, 48), (304, 150)] {
            #expect(SnipImages.pixel(plain, x, y) == SnipImages.pixel(outlined, x, y))
        }
    }

    @Test func keepsTheSnipsColorSpace() {
        let image = SnipRenderer.render(SnipImages.plain(), [], scale: 2)!
        #expect(image.colorSpace?.name == CGColorSpace.displayP3)
    }

    @Test(arguments: zip([Annotation.Thickness.thin, .thick], [4, 10]))
    func linesAreTheirThicknessInPixels(thickness: Annotation.Thickness, pixels: Int) {
        let line = Annotation(kind: .line, color: .red, thickness: thickness, start: CGPoint(x: 100, y: 50),
                              end: CGPoint(x: 100, y: 250))
        let image = SnipRenderer.render(SnipImages.plain(), [line], scale: 2)!
        #expect((80..<120).filter { SnipImages.isRed(SnipImages.pixel(image, $0, 150)) }.count == pixels)
    }

    @Test(arguments: zip([2.0, 1], [144.0, 72]))
    func keepsTheDPI(scale: CGFloat, dpi: Double) {
        let data = SnipRenderer.data(SnipImages.plain(), scale: scale)!
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyDPIWidth] as? Double == dpi)
        #expect(Snip(data: data)?.scale == scale)
    }

    @Test func makesTIFFForTheClipboard() {
        let data = SnipRenderer.data(SnipImages.plain(), scale: 2, type: .tiff)!
        let snip = Snip(data: data)
        #expect(snip?.pixelSize == CGSize(width: 400, height: 300))
        #expect(snip?.scale == 2)
    }
}

struct SnipTests {
    @Test func namedForWhenItWasTaken() {
        let utc = TimeZone(identifier: "UTC")!
        var components = DateComponents(year: 2026, month: 10, day: 4, hour: 14, minute: 32, second: 5)
        components.timeZone = utc
        let date = Calendar(identifier: .gregorian).date(from: components)!
        #expect(Snip.name(for: date, in: utc) == "Snip 2026-10-04 at 14.32.05")
    }

    @Test func sizeIsInPoints() {
        #expect(Snip(image: SnipImages.plain(width: 616, height: 430), scale: 2).size == CGSize(width: 308, height: 215))
    }

    @Test func noDPIMeansStandardScale() {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, SnipImages.plain(), nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(Snip(data: data as Data)?.scale == 1)
    }

    @Test func garbageIsntASnip() {
        #expect(Snip(data: Data("nonsense".utf8)) == nil)
    }
}

struct SnipFitTests {
    @Test func aRetinaSnipInALargeCanvasShowsAtActualSizeCentered() {
        let fit = SnipFit(CGSize(width: 616, height: 430), scale: 2, in: CGSize(width: 600, height: 400))
        #expect(fit.frame == CGRect(x: 146, y: 92, width: 308, height: 215))
        #expect(fit.pixelsPerPoint == 2)
    }

    @Test func aSmallCanvasScalesItDown() {
        let fit = SnipFit(CGSize(width: 2000, height: 1000), scale: 2, in: CGSize(width: 500, height: 500))
        #expect(fit.frame == CGRect(x: 0, y: 125, width: 500, height: 250))
        #expect(fit.pixelsPerPoint == 4)
    }

    @Test func pointerToPixelsAndBack() {
        let fit = SnipFit(CGSize(width: 2000, height: 1000), scale: 2, in: CGSize(width: 500, height: 500))
        let pixel = fit.pixel(for: CGPoint(x: 100, y: 200))
        #expect(pixel == CGPoint(x: 400, y: 300))
        #expect(fit.point(for: pixel) == CGPoint(x: 100, y: 200))
    }

    @Test func pointsOffTheSnipAreKeptOnIt() {
        let fit = SnipFit(CGSize(width: 2000, height: 1000), scale: 2, in: CGSize(width: 500, height: 500))
        #expect(fit.pixel(for: CGPoint(x: -50, y: 20)) == .zero)
        #expect(fit.pixel(for: CGPoint(x: 900, y: 900)) == CGPoint(x: 2000, y: 1000))
    }
}

struct SnipEditorLayoutTests {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func actualSizeWhenItFits() {
        #expect(SnipEditorLayout.contentSize(for: CGSize(width: 1000, height: 500), on: display)
                == CGSize(width: 1000, height: 544))
    }

    @Test func shrunkToFitNinetyPercentOfTheDisplay() {
        let size = SnipEditorLayout.contentSize(for: CGSize(width: 2000, height: 1200), on: display)
        #expect(size == CGSize(width: 1239, height: 788))
        // Same shape as the snip
        #expect(abs((size.width / (size.height - SnipEditorLayout.toolbarHeight)) - 2000 / 1200) < 0.01)
    }

    @Test func neverNarrowerThanTheToolbar() {
        #expect(SnipEditorLayout.contentSize(for: CGSize(width: 100, height: 50), on: display)
                == CGSize(width: SnipEditorLayout.minimumWidth,
                          height: SnipEditorLayout.minimumCanvasHeight + SnipEditorLayout.toolbarHeight))
    }
}

struct SnipTextTests {
    /// Where strongly colored pixels are, in a region
    private func box(_ image: CGImage, in region: CGRect, where match: ([Double]) -> Bool) -> CGRect? {
        var found: CGRect?
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) where match(SnipImages.pixel(image, x, y)) {
                let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                found = found?.union(pixel) ?? pixel
            }
        }
        return found
    }

    private func text(_ string: String, color: Annotation.Color = .red, at start: CGPoint = CGPoint(x: 100, y: 60),
                      size: CGFloat = 16, outline: Annotation.Outline = .white) -> Annotation {
        Annotation(kind: .text, color: color, thickness: .thin, start: start, end: start, text: string, textSize: size,
                   outline: outline)
    }

    @Test func itsTopLeftIsTheStartPoint() throws {
        let image = SnipRenderer.render(SnipImages.plain(), [text("Hi")], scale: 2)!
        let letters = try #require(box(image, in: CGRect(x: 60, y: 20, width: 300, height: 120), where: SnipImages.isRed))
        let font = SnipRenderer.textFont(size: 16, scale: 2)
        // Letters start just past the point, and capitals come up to their cap height
        #expect(letters.minX >= 100 && letters.minX <= 106)
        let capTop = 60 + CTFontGetAscent(font) - CTFontGetCapHeight(font)
        #expect(abs(letters.minY - capTop) <= 2)
        #expect(letters.height > CTFontGetCapHeight(font) - 3)
    }

    @Test func itsOutlineIsTheOneChosen() {
        let isWhite: ([Double]) -> Bool = { $0.allSatisfy { $0 > 0.95 } }
        let isBlack: ([Double]) -> Bool = { $0.allSatisfy { $0 < 0.05 } }
        let region = CGRect(x: 90, y: 50, width: 120, height: 70)
        let white = SnipRenderer.render(SnipImages.plain(), [text("Hi")], scale: 2)!
        #expect(box(white, in: region, where: isWhite) != nil)
        let black = SnipRenderer.render(SnipImages.plain(), [text("Hi", outline: .black)], scale: 2)!
        #expect(box(black, in: region, where: isBlack) != nil)
        #expect(box(black, in: region, where: isWhite) == nil)
        let none = SnipRenderer.render(SnipImages.plain(), [text("Hi", outline: .none)], scale: 2)!
        #expect(box(none, in: region, where: isWhite) == nil && box(none, in: region, where: isBlack) == nil)
    }

    @Test(arguments: Annotation.textSizes)
    func itsSizeIsInPoints(size: CGFloat) throws {
        let image = SnipRenderer.render(SnipImages.plain(), [text("H", size: size)], scale: 2)!
        let letter = try #require(box(image, in: CGRect(x: 90, y: 50, width: 80, height: 70), where: SnipImages.isRed))
        // A capital's height, at 2 pixels a point
        #expect(abs(letter.height - CTFontGetCapHeight(SnipRenderer.textFont(size: size, scale: 2))) <= 2)
    }

    @Test func blankTextDrawsNothing() {
        let snip = SnipImages.plain()
        let image = SnipRenderer.render(snip, [text("")], scale: 2)!
        for (x, y) in [(100, 60), (110, 80), (130, 90)] {
            #expect(SnipImages.pixel(image, x, y) == SnipImages.pixel(snip, x, y))
        }
    }

    @Test func shiftLeavesTextWhereItIs() {
        #expect(Annotation.constrained(.text, from: .zero, to: CGPoint(x: 30, y: 7)) == CGPoint(x: 30, y: 7))
    }
}
