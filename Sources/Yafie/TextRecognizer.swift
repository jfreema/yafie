import Foundation
import Vision

/// The text in a snip, read by Vision's text recognition on this Mac, in reading order with its line breaks
enum TextRecognizer {
    /// A run of text Vision found, and where: 0 to 1 across and up the snip, from its bottom left
    struct Fragment: Equatable {
        var text: String
        var box: CGRect
    }

    /// Nil if there's no text, or Vision couldn't read the snip. It takes a moment, so not on the main thread.
    static func text(in image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            snipLogger.error("Couldn't read the snip's text: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let fragments = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { Fragment(text: $0.string, box: observation.boundingBox) }
        }
        let text = lines(fragments)
        return text.isEmpty ? nil : text
    }

    /// A line apiece, top to bottom. Fragments side by side, like a message and its error code, share a line, left
    /// to right.
    static func lines(_ fragments: [Fragment]) -> String {
        var lines: [[Fragment]] = []
        for fragment in fragments.sorted(by: { $0.box.midY > $1.box.midY }) {
            let text = fragment.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let trimmed = Fragment(text: text, box: fragment.box)
            // Its middle is within the height of the line's first, which is the highest
            if let first = lines.last?.first, fragment.box.midY >= first.box.minY {
                lines[lines.count - 1].append(trimmed)
            } else {
                lines.append([trimmed])
            }
        }
        return lines.map { line in line.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }
}
