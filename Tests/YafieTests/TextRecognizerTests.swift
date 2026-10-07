import CoreGraphics
import Testing
@testable import Yafie

/// Where Vision found it: 0 to 1 across and up, from the bottom left
private func fragment(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 0.3, height: CGFloat = 0.1)
    -> TextRecognizer.Fragment {
    TextRecognizer.Fragment(text: text, box: CGRect(x: x, y: y, width: width, height: height))
}

struct TextRecognizerTests {
    @Test func linesGoTopToBottomWhateverOrderTheyreFound() {
        let found = [fragment("third", x: 0.1, y: 0.1), fragment("first", x: 0.1, y: 0.7),
                     fragment("second", x: 0.1, y: 0.4)]
        #expect(TextRecognizer.lines(found) == "first\nsecond\nthird")
    }

    @Test func sideBySideShareALineLeftToRight() {
        // A dialog's message beside its error code, with Vision's boxes a little uneven, as it found them
        let found = [fragment("Error 42", x: 0.71, y: 0.42, width: 0.15, height: 0.11),
                     fragment("Try again later", x: 0.03, y: 0.40, width: 0.27, height: 0.13),
                     fragment("The file couldn't be saved.", x: 0.03, y: 0.67, width: 0.5, height: 0.12)]
        #expect(TextRecognizer.lines(found) == "The file couldn't be saved.\nTry again later Error 42")
    }

    @Test func blankFragmentsAreLeftOut() {
        #expect(TextRecognizer.lines([fragment("  ", x: 0.1, y: 0.5), fragment(" OK ", x: 0.1, y: 0.2)]) == "OK")
        #expect(TextRecognizer.lines([]) == "")
    }

    @Test func readsTextWithItsLineBreaks() {
        let snip = SnipImages.text(["The file could not be saved", "Try again later"])
        #expect(TextRecognizer.text(in: snip) == "The file could not be saved\nTry again later")
    }

    @Test func noTextIsNil() {
        #expect(TextRecognizer.text(in: SnipImages.plain()) == nil)
    }
}
