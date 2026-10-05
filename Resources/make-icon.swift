#!/usr/bin/env swift
// Builds the icons and the other art from two masters: ./Resources/make-icon.swift
// Resources/AppIcon.png: 1024 pixels on Apple's macOS grid, an 824-pixel squircle with its shadow.
// Resources/MenuIcon.png: the menu bar glyph, black on clear.
// Writes Resources/AppIcon.icns, Resources/MenuIcon.tiff, Resources/MenuIconOutline.tiff,
// docs/icon.png and docs/social-preview.png.
// GitHub takes the social preview by hand: repo Settings → Social preview.

import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func load(_ path: String) -> CGImage {
    let url = root.appendingPathComponent(path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Couldn't read \(url.path)") }
    return image
}

let icon = load("Resources/AppIcon.png")
let menuGlyph = load("Resources/MenuIcon.png")

// MARK: Scenery

/// Measured down from the top, like Finder's icon positions
typealias Wave = (top: CGFloat, height: CGFloat, length: CGFloat, phase: CGFloat)

/// Pale sky over two waves in the icon's blues
func drawSea(_ ctx: CGContext, _ size: CGSize, back: Wave, front: Wave) {
    func y(_ fromTop: CGFloat) -> CGFloat { size.height - fromTop }
    ctx.drawLinearGradient(gradient([(0, color(0xF6FAFF)), (1, color(0xD4E6FF))]), start: CGPoint(x: 0, y: size.height),
                           end: CGPoint(x: 0, y: y(front.top)), options: [.drawsAfterEndLocation])
    let glow = CGPoint(x: size.width / 2, y: y(size.height / 10))
    ctx.drawRadialGradient(gradient([(0, color(0xFFFFFF, 0.9)), (1, color(0xFFFFFF, 0))]), startCenter: glow, startRadius: 0,
                           endCenter: glow, endRadius: size.width / 2, options: [])

    ctx.saveGState()
    ctx.addPath(wavePath(back, size))
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0x9CC4FF)), (1, color(0x5B93F2))]), start: CGPoint(x: 0, y: y(back.top - 10)),
                           end: CGPoint(x: 0, y: y(back.top + 78)), options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    // Deepens toward the bottom
    ctx.saveGState()
    ctx.addPath(wavePath(front, size))
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0x3B79E9)), (0.1, color(0x336ADC)), (1, color(0x13298F))]),
                           start: CGPoint(x: 0, y: y(front.top - 8)), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()
}

func wavePath(_ wave: Wave, _ size: CGSize) -> CGPath {
    let path = CGMutablePath()
    path.move(to: .zero)
    for x in stride(from: 0, through: size.width, by: 2) {
        path.addLine(to: CGPoint(x: x, y: size.height - wave.top - wave.height * sin(2 * .pi * x / wave.length + wave.phase)))
    }
    path.addLine(to: CGPoint(x: size.width, y: 0))
    path.closeSubpath()
    return path
}

func drawText(_ ctx: CGContext, _ text: String, size: CGFloat, weight: NSFont.Weight, color: CGColor,
              x: CGFloat, baseline: CGFloat, centered: Bool = false) {
    let system = NSFont.systemFont(ofSize: size, weight: weight)
    let font = system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? system
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]))
    let width = centered ? CTLineGetTypographicBounds(line, nil, nil, nil) : 0
    ctx.textPosition = CGPoint(x: x - width / 2, y: baseline)
    CTLineDraw(line, ctx)
}

// MARK: Social preview

func drawSocialPreview(_ ctx: CGContext) {
    let size = CGSize(width: 1280, height: 640)
    drawSea(ctx, size, back: (468, 14, 1000, 2.2), front: (512, 11, 760, 0.4))
    ctx.interpolationQuality = .high
    ctx.draw(icon, in: CGRect(x: 46, y: 112, width: 440, height: 440))
    drawText(ctx, "Yafie", size: 96, weight: .bold, color: color(0x0E2A75), x: 516, baseline: 368)
    drawText(ctx, "A Mac menu bar app with only the features", size: 31, weight: .medium, color: color(0x34466F),
             x: 520, baseline: 298)
    drawText(ctx, "I want and use, and nothing more.", size: 31, weight: .medium, color: color(0x34466F), x: 520, baseline: 254)
}

// MARK: Menu bar icon

// Points. A shade taller than the 14-point symbol it replaced, wide enough for the Y; outline weight to match Wi-Fi's.
let menuIconSize = CGSize(width: 16, height: 15)
let menuOutlineStroke: CGFloat = 1.2

func alphaMask(_ image: CGImage) -> [UInt8] {
    var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
    CGContext(data: &rgba, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
              space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (0..<image.width * image.height).map { rgba[$0 * 4 + 3] }
}

func blackImage(_ opaque: [Bool], width: Int, height: Int) -> CGImage {
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for pixel in opaque.indices where opaque[pixel] { rgba[pixel * 4 + 3] = 255 }
    return CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                     space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}

/// The glyph hollowed out, for when Yafie isn't keeping the Mac awake
func outlinedGlyph() -> CGImage {
    let (width, height) = (menuGlyph.width, menuGlyph.height)
    let ink = alphaMask(menuGlyph).map { $0 >= 128 }
    // Clear pixels reachable from the edge are outside; the rest of the clear ones are the face
    var outside = [Bool](repeating: false, count: width * height)
    var pending = Array(0..<width) + Array((height - 1) * width..<height * width)
        + stride(from: 0, to: width * height, by: width).flatMap { [$0, $0 + width - 1] }
    while let pixel = pending.popLast() {
        guard !outside[pixel], !ink[pixel] else { continue }
        outside[pixel] = true
        let x = pixel % width
        if x > 0 { pending.append(pixel - 1) }
        if x < width - 1 { pending.append(pixel + 1) }
        if pixel >= width { pending.append(pixel - width) }
        if pixel < (height - 1) * width { pending.append(pixel + width) }
    }
    let silhouette = outside.map { !$0 }
    // Shrinking the silhouette by the stroke width leaves the ring
    let stroke = menuOutlineStroke * CGFloat(height) / menuIconSize.height
    let shrunk = CIImage(cgImage: blackImage(silhouette, width: width, height: height))
        .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: stroke])
    let inner = alphaMask(CIContext().createCGImage(shrunk, from: CGRect(x: 0, y: 0, width: width, height: height))!)
    let outline = silhouette.indices.map { silhouette[$0] && (inner[$0] < 128 || !ink[$0]) }
    return blackImage(outline, width: width, height: height)
}

/// Fitted to the icon's height, centered across its width
func drawMenuIcon(_ glyph: CGImage) -> (CGContext) -> Void {
    { ctx in
        let width = menuIconSize.height * CGFloat(glyph.width) / CGFloat(glyph.height)
        ctx.interpolationQuality = .high
        ctx.draw(glyph, in: CGRect(x: (menuIconSize.width - width) / 2, y: 0, width: width, height: menuIconSize.height))
    }
}

// MARK: Output

func render(_ width: Int, _ height: Int, scale: CGFloat = 1, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    draw(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(url.path)") }
}

func scaledIcon(_ pixels: Int) -> CGImage {
    render(pixels, pixels) { ctx in
        ctx.interpolationQuality = .high
        ctx.draw(icon, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    }
}

func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("\(tool) failed") }
}

let files = FileManager.default
let scratch = files.temporaryDirectory.appendingPathComponent("yafie-art-\(UUID().uuidString)")
let iconset = scratch.appendingPathComponent("AppIcon.iconset")
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? files.removeItem(at: scratch) }

for points in [16, 32, 128, 256, 512] {
    for (suffix, pixels) in [("", points), ("@2x", points * 2)] {
        writePNG(scaledIcon(pixels), to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path])

// Menu bar icons, each one TIFF holding both resolutions
for (name, glyph) in [("MenuIcon", menuGlyph), ("MenuIconOutline", outlinedGlyph())] {
    let png1x = scratch.appendingPathComponent("\(name).png"), png2x = scratch.appendingPathComponent("\(name)@2x.png")
    let (width, height) = (Int(menuIconSize.width), Int(menuIconSize.height))
    writePNG(render(width, height, drawMenuIcon(glyph)), to: png1x)
    writePNG(render(width * 2, height * 2, scale: 2, drawMenuIcon(glyph)), to: png2x)
    try run("/usr/bin/tiffutil", ["-cathidpicheck", png1x.path, png2x.path,
                                  "-out", root.appendingPathComponent("Resources/\(name).tiff").path])
}

let docs = root.appendingPathComponent("docs")
try files.createDirectory(at: docs, withIntermediateDirectories: true)
writePNG(scaledIcon(512), to: docs.appendingPathComponent("icon.png"))
writePNG(render(1280, 640, drawSocialPreview), to: docs.appendingPathComponent("social-preview.png"))
print("Wrote Resources/AppIcon.icns, Resources/MenuIcon.tiff, Resources/MenuIconOutline.tiff, docs/icon.png and docs/social-preview.png")
