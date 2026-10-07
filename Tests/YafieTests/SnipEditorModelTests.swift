import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Yafie

@MainActor
struct SnipEditorModelTests {
    /// In memory, so the tests neither change Yafie's settings nor leave files behind
    private let settings = MemorySettings()

    private func model() -> SnipEditorModel {
        SnipEditorModel(snip: Snip(image: SnipImages.plain(), scale: 2), defaults: settings)
    }

    private func draw(_ model: SnipEditorModel, from start: CGPoint, to end: CGPoint, shift: Bool = false) {
        model.begin(at: start)
        model.move(to: end, constrained: shift)
        model.end()
    }

    @Test func startsWithAThinRedBox() {
        let model = model()
        #expect(model.tool == .box && model.color == .red && model.thickness == .thin)
        #expect(model.outline == .white && model.textSize == 16)
        #expect(!model.canUndo && !model.canRedo && !model.hasUnsavedShapes)
    }

    @Test func aDragDrawsWithTheCurrentToolColorAndThickness() {
        let model = model()
        model.tool = .arrow
        model.color = .blue
        model.thickness = .thick
        model.begin(at: CGPoint(x: 10, y: 10))
        model.move(to: CGPoint(x: 60, y: 30), constrained: false)
        #expect(model.drawing?.end == CGPoint(x: 60, y: 30))
        #expect(model.shapes.isEmpty)
        model.end()
        #expect(model.drawing == nil)
        #expect(model.shapes == [Annotation(kind: .arrow, color: .blue, thickness: .thick, start: CGPoint(x: 10, y: 10),
                                            end: CGPoint(x: 60, y: 30), outline: .white)])
    }

    @Test func highlightsHaveNoOutline() {
        let model = model()
        model.tool = .highlight
        model.outline = .black
        draw(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 30))
        #expect(model.shapes.first?.outline == Annotation.Outline.none)
    }

    @Test func aDragShorterThanFourPointsMakesNoShape() {
        let model = model()
        // 4 points is 8 pixels at a Retina snip's scale
        draw(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 17, y: 10))
        #expect(model.shapes.isEmpty)
        #expect(!model.canUndo)
        draw(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 18, y: 10))
        #expect(model.shapes.count == 1)
    }

    @Test func shiftConstrainsWhileDrawing() {
        let model = model()
        model.tool = .line
        draw(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 14), shift: true)
        #expect(abs((model.shapes.first?.end.y ?? 0) - 10) < 1e-9)
    }

    @Test func undoAndRedo() {
        let model = model()
        for x in [100.0, 200, 300] { draw(model, from: CGPoint(x: x, y: 10), to: CGPoint(x: x, y: 100)) }
        model.undo()
        model.undo()
        #expect(model.shapes.count == 1)
        model.redo()
        #expect(model.shapes.count == 2)
        #expect(model.canRedo)
        draw(model, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 150))
        #expect(model.shapes.count == 3)
        #expect(!model.canRedo)
        #expect(model.shapes.last?.start == CGPoint(x: 50, y: 50))
    }

    @Test func copyOrSaveClearsTheChangedFlag() {
        let model = model()
        draw(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100))
        #expect(model.hasUnsavedShapes)
        model.kept()
        #expect(!model.hasUnsavedShapes)
        draw(model, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 100, y: 100))
        #expect(model.hasUnsavedShapes)
        // With every shape undone there's nothing to lose
        model.undo()
        model.undo()
        #expect(!model.hasUnsavedShapes)
    }

    @Test func switchingThicknessLeavesDrawnShapesAlone() {
        let model = model()
        draw(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100))
        model.thickness = .thick
        #expect(model.shapes.first?.thickness == .thin)
    }

    @Test func theHighlighterHasItsOwnColorStartingYellow() {
        let model = model()
        model.tool = .highlight
        #expect(model.color == .yellow)
        model.color = .green
        model.tool = .arrow
        #expect(model.color == .red)
        model.color = .blue
        model.tool = .highlight
        #expect(model.color == .green)
        draw(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100))
        #expect(model.shapes.last?.kind == .highlight && model.shapes.last?.color == .green)

        let next = self.model()
        #expect(next.color == .green)  // still on the highlighter
        next.tool = .box
        #expect(next.color == .blue)
    }

    @Test func remembersTheLastToolColorThicknessOutlineAndSize() {
        let first = model()
        first.tool = .arrow
        first.color = .yellow
        first.thickness = .thick
        first.outline = .black
        first.textSize = 12
        let second = model()
        #expect(second.tool == .arrow && second.color == .yellow && second.thickness == .thick)
        #expect(second.outline == .black && second.textSize == 12)
    }

    @Test func aTextSizeThatsNoLongerOfferedGoesBackTo16() {
        settings.set("24", forKey: "snipTextSize")
        #expect(model().textSize == 16)
    }

    @Test func rendersItsShapesAtFullResolution() {
        let model = model()
        draw(model, from: CGPoint(x: 100, y: 50), to: CGPoint(x: 300, y: 250))
        let image = model.rendered()
        #expect(image?.width == 400 && image?.height == 300)
        #expect(image.map { SnipImages.isRed(SnipImages.pixel($0, 100, 150)) } == true)
    }
}

@MainActor
struct SnipEditorTextTests {
    /// In memory, so the tests neither change Yafie's settings nor leave files behind
    private let settings = MemorySettings()

    private func model() -> SnipEditorModel {
        let model = SnipEditorModel(snip: Snip(image: SnipImages.plain(), scale: 2), defaults: settings)
        model.tool = .text
        return model
    }


    @Test func returnPlacesTheText() {
        let model = model()
        model.beginText(at: CGPoint(x: 40, y: 30))
        #expect(model.isEditingText)
        model.updateText("Look here")
        model.commitText()
        #expect(!model.isEditingText)
        #expect(model.shapes == [Annotation(kind: .text, color: .red, thickness: .thin, start: CGPoint(x: 40, y: 30),
                                            end: CGPoint(x: 40, y: 30), text: "Look here", textSize: 16,
                                            outline: .white)])
        #expect(model.canUndo && model.hasUnsavedShapes)
    }

    @Test func blankTextIsDropped() {
        let model = model()
        model.beginText(at: CGPoint(x: 40, y: 30))
        model.updateText("   ")
        model.commitText()
        #expect(model.shapes.isEmpty && !model.canUndo)
    }

    @Test func escDropsTheText() {
        let model = model()
        model.beginText(at: CGPoint(x: 40, y: 30))
        model.updateText("Never mind")
        model.cancelText()
        #expect(model.shapes.isEmpty && !model.isEditingText)
    }

    @Test func clickingElsewherePlacesItAndStartsAnother() {
        let model = model()
        model.beginText(at: CGPoint(x: 40, y: 30))
        model.updateText("One")
        model.beginText(at: CGPoint(x: 200, y: 100))
        #expect(model.shapes.map(\.text) == ["One"])
        #expect(model.draft?.start == CGPoint(x: 200, y: 100))
    }

    @Test func switchingToolsPlacesIt() {
        let model = model()
        model.beginText(at: CGPoint(x: 40, y: 30))
        model.updateText("One")
        model.tool = .arrow
        #expect(model.shapes.map(\.text) == ["One"] && !model.isEditingText)
    }

    @Test func colorSizeAndOutlineApplyToTheTextBeingTyped() {
        let model = model()
        model.beginText(at: CGPoint(x: 40, y: 30))
        model.color = .blue
        model.textSize = 12
        model.outline = .black
        #expect(model.draft?.color == .blue && model.draft?.textSize == 12 && model.draft?.outline == .black)
    }

    @Test func textUsesThePenColorNotTheHighlighters() {
        let model = model()
        model.tool = .highlight
        model.color = .green
        model.tool = .text
        #expect(model.color == .red)
    }

    @Test func dragsDontDrawWithTheTextTool() {
        let model = model()
        model.begin(at: CGPoint(x: 10, y: 10))
        model.move(to: CGPoint(x: 100, y: 100), constrained: false)
        model.end()
        #expect(model.shapes.isEmpty)
    }
}

@MainActor
struct SnipMenuTests {
    private func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.compactMap(\.submenu).flatMap(\.items) }

    @Test func commandQClosesTheEditorsNotYafie() throws {
        _ = NSApplication.shared
        let editors = SnipEditors()
        let items = items(SnipMenu.make(editors: editors))
        let commandQ = try #require(items.first { $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == .command })
        #expect(commandQ.action == #selector(SnipEditors.quitEditors(_:)))
        #expect(commandQ.target === editors)
        let quit = try #require(items.first { $0.action == #selector(NSApplication.terminate(_:)) })
        #expect(quit.keyEquivalent.isEmpty)
    }

    @Test func singleKeysOnlyWhileTurnedOn() throws {
        _ = NSApplication.shared
        let menu = SnipMenu.make()
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = nil }
        let box = try #require(items(menu).first { $0.title == "Box" })
        #expect(box.keyEquivalent.isEmpty)
        SnipMenu.setSingleKeys(true)
        #expect(box.keyEquivalent == "r" && box.keyEquivalentModifierMask.isEmpty)
        SnipMenu.setSingleKeys(false)
        #expect(box.keyEquivalent.isEmpty)
    }
}
