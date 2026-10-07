import AppKit
import SwiftUI

/// The open editors. While any is open, Yafie is a regular app, with a Dock icon, ⌘Tab and a menu bar.
@MainActor
final class SnipEditors: NSObject {
    private var editors: [SnipEditorController] = []
    /// Gets the focus back when the last editor closes
    private var previousApp: NSRunningApplication?

    var isOpen: Bool { !editors.isEmpty }
    /// Editors with shapes that would be lost
    var unsaved: Int { editors.filter { $0.model.hasUnsavedShapes }.count }

    func open(_ snip: Snip, returningTo app: NSRunningApplication?) {
        if editors.isEmpty {
            previousApp = app
            NSApp.setActivationPolicy(.regular)
            NSApp.mainMenu = SnipMenu.make(editors: self)
        }
        let editor = SnipEditorController(snip: snip, near: NSEvent.mouseLocation)
        editor.onClose = { [weak self, weak editor] in
            if let editor { self?.closed(editor) }
        }
        if let last = editors.last {
            editor.window.setFrameTopLeftPoint(NSPoint(x: last.window.frame.minX + 24, y: last.window.frame.maxY - 24))
        }
        editors.append(editor)
        NSApp.activateRegardless()
        editor.window.makeKeyAndOrderFront(nil)
        // On top even if macOS kept another app active, so a click brings it the rest of the way
        editor.window.orderFrontRegardless()
        snipLogger.notice("Opened a snip in the editor")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if !NSApp.isActive { snipLogger.error("macOS kept Yafie in the background") }
        }
    }

    /// ⌘Q in an editor closes the editors, each asking about unsaved shapes, and leaves Yafie in the menu bar.
    /// Quitting Yafie would also stop Stay Awake and window snapping.
    @objc func quitEditors(_ sender: Any?) {
        for editor in editors { editor.window.performClose(nil) }
    }

    /// Yafie's Dock icon, clicked
    func bringForward() {
        NSApp.activateRegardless()
        editors.last?.window.makeKeyAndOrderFront(nil)
    }

    private func closed(_ editor: SnipEditorController) {
        editors.removeAll { $0 === editor }
        guard editors.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = nil
        NSApp.handFocus(back: previousApp)
        previousApp = nil
    }
}

/// The menu bar while an editor is open. Its items carry every shortcut.
@MainActor
enum SnipMenu {
    /// The single-key shortcuts, like R for Box, are only there while an editor has the keyboard and no text is being
    /// typed. A menu item takes its key even while it's disabled, so otherwise typing r in a text, or in a Save
    /// dialog's name, would do nothing.
    static func setSingleKeys(_ on: Bool) {
        for item in NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? [] {
            guard let key = item.representedObject as? String else { continue }
            item.keyEquivalent = on ? key : ""
        }
    }

    /// - Parameter editors: what ⌘Q closes. Without them, as for a Save dialog from a snip's menu, ⌘Q does nothing.
    static func make(editors: SnipEditors? = nil) -> NSMenu {
        let bar = NSMenu()
        let quitEditors = item("Quit Snip Editor", #selector(SnipEditors.quitEditors(_:)), "q")
        quitEditors.target = editors
        add("Yafie", to: bar, [
            item("About Yafie", #selector(AppDelegate.showAbout)),
            .separator(),
            item("Hide Yafie", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            quitEditors,
            item("Quit Yafie", #selector(NSApplication.terminate(_:))),  // no ⌘Q: that closes the editors
        ])
        add("File", to: bar, [
            item("Save…", #selector(SnipEditorController.saveSnip(_:)), "s"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        // Cut, Copy, Paste and Select All are the standard ones, so text fields get them too. Copy copies the snip when
        // an editor has the keyboard.
        add("Edit", to: bar, [
            item("Undo", #selector(SnipEditorController.undoShape(_:)), "z"),
            item("Redo", #selector(SnipEditorController.redoShape(_:)), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let tools = zip(["Box", "Line", "Arrow", "Highlight", "Text"], ["r", "l", "a", "h", "t"]).enumerated()
            .map { index, tool in singleKey(tool.0, #selector(SnipEditorController.chooseTool(_:)), tool.1, tag: index) }
        let colors = Annotation.Color.allCases.enumerated().map { index, color in
            singleKey(color.name, #selector(SnipEditorController.chooseColor(_:)), "\(index + 1)", tag: index)
        }
        add("Tools", to: bar, tools + [.separator()] + colors + [
            .separator(),
            singleKey("Thick", #selector(SnipEditorController.toggleThickness(_:)), "w"),
        ])
        let window = add("Window", to: bar, [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window
        return bar
    }

    @discardableResult
    private static func add(_ title: String, to bar: NSMenu, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        for item in items { menu.addItem(item) }
        bar.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }

    /// Sent along the responder chain, to whatever window has the keyboard
    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    /// Its key is held back until setSingleKeys turns it on
    private static func singleKey(_ title: String, _ action: Selector, _ key: String, tag: Int = 0) -> NSMenuItem {
        let item = item(title, action, "", [], tag: tag)
        item.representedObject = key
        return item
    }
}

/// One snip's editor window
@MainActor
final class SnipEditorController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    let model: SnipEditorModel
    let window: NSWindow
    var onClose: (() -> Void)?

    /// Centered on the display with that point, at the snip's actual size if it fits
    init(snip: Snip, near point: NSPoint) {
        model = SnipEditorModel(snip: snip)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
        let size = SnipEditorLayout.contentSize(for: snip.size, on: visible)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        super.init()
        let content = NSHostingView(rootView: SnipEditorView(model: model,
                                                             copy: { [weak self] in self?.copy(nil) },
                                                             save: { [weak self] in self?.saveSnip(nil) }))
        // The window decides its size, down to the toolbar's minimum
        content.sizingOptions = [.minSize]
        window.contentView = content
        window.title = snip.name
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        window.setFrameOrigin(NSPoint(x: (visible.midX - frame.width / 2).rounded(),
                                      y: (visible.midY - frame.height / 2).rounded()))
        observeChanges()
    }

    // MARK: Menu bar actions

    @objc func copy(_ sender: Any?) {
        model.commitText()
        guard let image = model.rendered(), SnipOutput.copy(image, scale: model.snip.scale) else { return NSSound.beep() }
        model.kept()
        snipLogger.notice("Copied the snip from the editor")
    }

    @objc func saveSnip(_ sender: Any?) {
        model.commitText()
        guard let image = model.rendered() else { return NSSound.beep() }
        SnipOutput.save(image, scale: model.snip.scale, name: model.snip.name, from: window) { [weak self] saved in
            guard saved, let self else { return }
            model.kept()
            window.close()
        }
    }

    @objc func undoShape(_ sender: Any?) { model.undo() }
    @objc func redoShape(_ sender: Any?) { model.redo() }
    @objc func chooseTool(_ sender: NSMenuItem) { model.tool = Annotation.Kind.allCases[sender.tag] }
    @objc func chooseColor(_ sender: NSMenuItem) { model.color = Annotation.Color.allCases[sender.tag] }
    @objc func toggleThickness(_ sender: Any?) { model.thickness = model.thickness == .thin ? .thick : .thin }

    /// Everything here needs this editor to have the keyboard, so nothing acts on a window behind a dialog
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard window.isKeyWindow else { return false }
        switch item.action {
        case #selector(undoShape(_:)): return model.canUndo && !model.isEditingText
        case #selector(redoShape(_:)): return model.canRedo && !model.isEditingText
        case #selector(chooseTool(_:)): item.state = Annotation.Kind.allCases[item.tag] == model.tool ? .on : .off
        case #selector(chooseColor(_:)): item.state = Annotation.Color.allCases[item.tag] == model.color ? .on : .off
        case #selector(toggleThickness(_:)):
            item.state = model.thickness == .thick ? .on : .off
            return model.tool != .highlight && model.tool != .text  // highlights are filled, and text has a size
        default: break
        }
        return true
    }

    // MARK: Closing

    /// Shapes that haven't been copied or saved get a chance first
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.commitText()
        guard model.hasUnsavedShapes else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save this snip?"
        alert.informativeText = "Its shapes will be lost if you don't copy or save it."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Don't Save")
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        discard.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: saveSnip(nil)
            case .alertThirdButtonReturn: window.close()
            default: break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // Once the window's done closing, since the list of editors holds the last reference to it
        Task { @MainActor [weak self] in self?.onClose?() }
    }

    func windowDidBecomeKey(_ notification: Notification) { updateSingleKeys() }
    func windowDidResignKey(_ notification: Notification) { SnipMenu.setSingleKeys(false) }

    private func updateSingleKeys() {
        SnipMenu.setSingleKeys(window.isKeyWindow && !model.isEditingText)
    }

    /// The close button's unsaved dot, and the single keys, which stay out of the way of typing
    private func observeChanges() {
        withObservationTracking {
            window.isDocumentEdited = model.hasUnsavedShapes
            updateSingleKeys()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeChanges() }
        }
    }
}

// MARK: Model

/// Where the editor keeps the last tool, color, thickness, outline and text size: UserDefaults, or memory in tests
protocol EditorSettings: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: EditorSettings {}

/// One snip in the editor: its shapes, with undo and redo, and the tool, color, thickness, outline and text size for
/// the next one
@Observable @MainActor
final class SnipEditorModel {
    /// Shorter drags than this, in points, make no shape, so a click doesn't leave a dot
    static let shortestDrag: CGFloat = 4

    let snip: Snip
    private(set) var shapes: [Annotation] = []
    /// The shape following the pointer, until the drag ends
    private(set) var drawing: Annotation?
    /// The text being typed, until Return, Esc or a click elsewhere
    private(set) var draft: Annotation?
    /// Shapes added or taken away since the last Copy or Save
    private(set) var isChanged = false
    private var undos: [[Annotation]] = []
    private var redos: [[Annotation]] = []

    // The last ones used, for the next snip too
    var tool: Annotation.Kind {
        didSet {
            defaults.set(tool.rawValue, forKey: Keys.tool)
            commitText()
        }
    }
    var thickness: Annotation.Thickness {
        didSet { defaults.set(thickness.rawValue, forKey: Keys.thickness) }
    }
    /// Boxes, lines, arrows and text share an outline. Highlights have none.
    var outline: Annotation.Outline {
        didSet {
            defaults.set(outline.rawValue, forKey: Keys.outline)
            draft?.outline = outline
        }
    }
    /// In points, one of Annotation.textSizes
    var textSize: CGFloat {
        didSet {
            defaults.set(String(Int(textSize)), forKey: Keys.textSize)
            draft?.textSize = textSize
        }
    }
    /// Boxes, lines, arrows and text share a color. The highlighter has its own, so highlights start yellow.
    var color: Annotation.Color {
        get { tool == .highlight ? highlightColor : penColor }
        set {
            if tool == .highlight { highlightColor = newValue } else { penColor = newValue }
            draft?.color = newValue
        }
    }
    private var penColor: Annotation.Color {
        didSet { defaults.set(penColor.rawValue, forKey: Keys.color) }
    }
    private var highlightColor: Annotation.Color {
        didSet { defaults.set(highlightColor.rawValue, forKey: Keys.highlightColor) }
    }

    @ObservationIgnored private let defaults: EditorSettings

    private enum Keys {
        static let tool = "snipTool"
        static let color = "snipColor"
        static let highlightColor = "snipHighlightColor"
        static let thickness = "snipThickness"
        static let outline = "snipOutline"
        static let textSize = "snipTextSize"
    }

    init(snip: Snip, defaults: EditorSettings = UserDefaults.standard) {
        self.snip = snip
        self.defaults = defaults
        tool = defaults.string(forKey: Keys.tool).flatMap(Annotation.Kind.init) ?? .box
        penColor = defaults.string(forKey: Keys.color).flatMap(Annotation.Color.init) ?? .red
        highlightColor = defaults.string(forKey: Keys.highlightColor).flatMap(Annotation.Color.init) ?? .yellow
        thickness = defaults.string(forKey: Keys.thickness).flatMap(Annotation.Thickness.init) ?? .thin
        // White and 16 points, as text was before there was a choice
        outline = defaults.string(forKey: Keys.outline).flatMap(Annotation.Outline.init) ?? .white
        let size = defaults.string(forKey: Keys.textSize).flatMap(Double.init).map { CGFloat($0) }
        textSize = size.flatMap { Annotation.textSizes.contains($0) ? $0 : nil } ?? 16
    }

    var canUndo: Bool { !undos.isEmpty }
    var canRedo: Bool { !redos.isEmpty }
    /// Shapes that closing would lose
    var hasUnsavedShapes: Bool { isChanged && !shapes.isEmpty }
    var isEditingText: Bool { draft != nil }

    /// In the snip's pixels. Text is placed with beginText instead.
    func begin(at pixel: CGPoint) {
        guard tool != .text else { return }
        drawing = Annotation(kind: tool, color: color, thickness: thickness, start: pixel, end: pixel,
                             outline: tool == .highlight ? .none : outline)
    }

    /// A new text, its top left at that pixel
    func beginText(at pixel: CGPoint) {
        commitText()
        draft = Annotation(kind: .text, color: color, thickness: thickness, start: pixel, end: pixel,
                           textSize: textSize, outline: outline)
    }

    func updateText(_ text: String) {
        draft?.text = text
    }

    /// The text joins the shapes, unless it's blank
    func commitText() {
        guard var text = draft else { return }
        draft = nil
        text.text = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.text.isEmpty else { return }
        add(text)
    }

    func cancelText() {
        draft = nil
    }

    func move(to pixel: CGPoint, constrained: Bool) {
        guard var shape = drawing else { return }
        shape.end = constrained ? Annotation.constrained(shape.kind, from: shape.start, to: pixel) : pixel
        drawing = shape
    }

    func end() {
        guard let shape = drawing else { return }
        drawing = nil
        guard hypot(shape.end.x - shape.start.x, shape.end.y - shape.start.y) >= Self.shortestDrag * snip.scale
        else { return }
        add(shape)
    }

    private func add(_ shape: Annotation) {
        undos.append(shapes)
        redos.removeAll()
        shapes.append(shape)
        isChanged = true
    }

    func undo() {
        guard let previous = undos.popLast() else { return }
        redos.append(shapes)
        shapes = previous
        isChanged = true
    }

    func redo() {
        guard let next = redos.popLast() else { return }
        undos.append(shapes)
        shapes = next
        isChanged = true
    }

    /// After a Copy or Save
    func kept() { isChanged = false }

    /// The snip with its shapes, at full resolution
    func rendered() -> CGImage? { SnipRenderer.render(snip.image, shapes, scale: snip.scale) }
}

extension Annotation.Color {
    var name: String { rawValue.capitalized }
}

// MARK: Views

/// The toolbar, then the snip with its shapes. All its state is in the model: the Command Line Tools can't build
/// SwiftUI's @State.
struct SnipEditorView: View {
    let model: SnipEditorModel
    let copy: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SnipToolbar(model: model, copy: copy, save: save)
                .frame(height: SnipEditorLayout.toolbarHeight)
                // Inside the toolbar's height, so a snip at actual size gets every point it needs
                .overlay(alignment: .bottom) { Divider() }
            SnipCanvas(model: model)
        }
        .frame(minWidth: SnipEditorLayout.minimumWidth,
               minHeight: SnipEditorLayout.toolbarHeight + SnipEditorLayout.minimumCanvasHeight)
    }
}

private struct SnipToolbar: View {
    let model: SnipEditorModel
    let copy: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Picker("Tool", selection: Binding(get: { model.tool }, set: { model.tool = $0 })) {
                Image(systemName: "rectangle").accessibilityLabel("Box").tag(Annotation.Kind.box)
                Image(systemName: "line.diagonal").accessibilityLabel("Line").tag(Annotation.Kind.line)
                Image(systemName: "arrow.up.right").accessibilityLabel("Arrow").tag(Annotation.Kind.arrow)
                Image(systemName: "highlighter").accessibilityLabel("Highlight").tag(Annotation.Kind.highlight)
                Image(systemName: "textformat").accessibilityLabel("Text").tag(Annotation.Kind.text)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Box (R), Line (L), Arrow (A), Highlight (H) or Text (T)")

            HStack(spacing: 2) {
                ForEach(Array(Annotation.Color.allCases.enumerated()), id: \.element) { index, color in
                    Swatch(color: color, isCurrent: model.color == color) { model.color = color }
                        .help("\(color.name) (\(index + 1))")
                }
            }

            Picker("Thickness", selection: Binding(get: { model.thickness }, set: { model.thickness = $0 })) {
                Text("Thin").tag(Annotation.Thickness.thin)
                Text("Thick").tag(Annotation.Thickness.thick)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.tool == .highlight || model.tool == .text)  // highlights are filled, and text has a size
            .help("Thin or thick lines (W)")

            Picker("Outline", selection: Binding(get: { model.outline }, set: { model.outline = $0 })) {
                ForEach(Annotation.Outline.allCases, id: \.self) { outline in
                    Text(outline.rawValue.capitalized).tag(outline)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(model.tool == .highlight)  // highlights have none
            .help("An outline around boxes, lines, arrows and text, so they stand out")

            Picker("Size", selection: Binding(get: { model.textSize }, set: { model.textSize = $0 })) {
                ForEach(Annotation.textSizes, id: \.self) { size in
                    Text("\(Int(size)) pt").tag(size)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(model.tool != .text)
            .help("Text size")

            HStack(spacing: 4) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo)
                    .help("Undo (⌘Z)")
                    .accessibilityLabel("Undo")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.canRedo)
                    .help("Redo (⇧⌘Z)")
                    .accessibilityLabel("Redo")
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 0)
            Button("Copy", action: copy)
                .help("Copy to Clipboard (⌘C)")
            Button("Save…", action: save)
                .help("Save (⌘S)")
        }
        .padding(.horizontal, 12)
    }
}

private struct Swatch: View {
    let color: Annotation.Color
    let isCurrent: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Circle()
                .fill(Color(cgColor: color.cgColor))
                .frame(width: 16, height: 16)
                .padding(3)
                .overlay(Circle().strokeBorder(Color.primary.opacity(isCurrent ? 0.75 : 0), lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// The snip, with its shapes over it. Dragging on the snip draws, and with the Text tool, a click places a text.
private struct SnipCanvas: View {
    let model: SnipEditorModel

    var body: some View {
        let snip = model.snip
        // Read here, so a change redraws
        let shapes = model.shapes + (model.drawing.map { [$0] } ?? [])
        let draft = model.draft
        let isText = model.tool == .text
        GeometryReader { geometry in
            let fit = SnipFit(snip.pixelSize, scale: snip.scale, in: geometry.size)
            ZStack {
                Image(decorative: snip.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.frame.width, height: fit.frame.height)
                    .position(x: fit.frame.midX, y: fit.frame.midY)
                PointerArea(isText: isText)
                    .frame(width: fit.frame.width, height: fit.frame.height)
                    .position(x: fit.frame.midX, y: fit.frame.midY)
                Canvas { context, _ in
                    context.withCGContext { cg in
                        cg.translateBy(x: fit.frame.minX, y: fit.frame.minY)
                        cg.scaleBy(x: 1 / fit.pixelsPerPoint, y: 1 / fit.pixelsPerPoint)
                        SnipRenderer.draw(shapes, in: cg, scale: snip.scale)
                    }
                }
                .allowsHitTesting(false)
                if let draft {
                    let origin = fit.point(for: draft.start)
                    TextEntry(model: model, color: Color(cgColor: draft.color.cgColor),
                              size: draft.textSize * snip.scale / fit.pixelsPerPoint)
                        .frame(width: max(40, fit.frame.maxX - origin.x), alignment: .leading)
                        .padding(.leading, origin.x + TextEntry.offset.x)
                        .padding(.top, origin.y + TextEntry.offset.y)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                        .id("\(draft.start.x),\(draft.start.y)")  // a new field for each text, so it takes the keyboard
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard !isText else { return }
                    if model.drawing == nil {
                        guard fit.frame.contains(drag.startLocation) else { return }
                        model.begin(at: fit.pixel(for: drag.startLocation))
                    }
                    model.move(to: fit.pixel(for: drag.location), constrained: NSEvent.modifierFlags.contains(.shift))
                }
                .onEnded { drag in
                    guard isText else { return model.end() }
                    guard fit.frame.contains(drag.startLocation) else { return model.commitText() }
                    model.beginText(at: fit.pixel(for: drag.startLocation))
                })
        }
        .clipped()
    }
}

/// Where a text is typed, over the spot where it's drawn. Return places it, Esc drops it, and so does a click
/// elsewhere, which places it.
private struct TextEntry: View {
    /// From the text's top left to the field's, so the letters don't move when the text is placed
    static let offset = CGPoint(x: 0, y: 0)

    let model: SnipEditorModel
    let color: Color
    /// In the canvas's points
    let size: CGFloat
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: Binding(get: { model.draft?.text ?? "" }, set: { model.updateText($0) }))
            .textFieldStyle(.plain)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onSubmit { model.commitText() }
            .onExitCommand { model.cancelText() }
            .onChange(of: isFocused) { _, focused in
                if !focused { model.commitText() }
            }
    }
}

/// The pointer over the snip: a crosshair, or an I-beam for text. Clicks go through it to the canvas.
private struct PointerArea: NSViewRepresentable {
    let isText: Bool

    func makeNSView(context: Context) -> PointerView { PointerView() }

    func updateNSView(_ view: PointerView, context: Context) {
        guard view.isText != isText else { return }
        view.isText = isText
        view.window?.invalidateCursorRects(for: view)
    }
}

private final class PointerView: NSView {
    var isText = false

    override func resetCursorRects() { addCursorRect(bounds, cursor: isText ? .iBeam : .crosshair) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        window?.invalidateCursorRects(for: self)
    }
}
