import CoreGraphics
import CoreText
import Foundation
@testable import Yafie

/// Stand-in snips
enum SnipImages {
    /// Plain mid-gray, in Display P3 like a recent Mac's screenshots
    static func plain(width: Int = 400, height: Int = 300,
                      space: CGColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Red, green and blue from 0 to 1 at a pixel, counting from the top left, in sRGB
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Double] {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<3).map { Double(bytes[$0]) / 255 }
    }

    static func isRed(_ color: [Double]) -> Bool { color[0] > 0.95 && color[1] < 0.35 && color[2] < 0.3 }

    /// Black text on white, a line apiece from the top, big enough for Vision to read easily
    static func text(_ lines: [String], width: Int = 900) -> CGImage {
        let lineHeight = 80
        let height = lineHeight * lines.count + 40
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let helvetica = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        let font = [NSAttributedString.Key(kCTFontAttributeName as String): helvetica]
        for (index, text) in lines.enumerated() {
            let string = NSAttributedString(string: text, attributes: font)
            context.textPosition = CGPoint(x: 30, y: height - lineHeight * (index + 1))
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        return context.makeImage()!
    }
}

/// The editor's settings, in memory
final class MemorySettings: EditorSettings {
    private var values: [String: Any] = [:]

    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
