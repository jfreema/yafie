import AppKit
import Carbon.HIToolbox
import os

let snipLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "yafie", category: "snip")

/// ⌃⌥P snips part of the screen with macOS's own selection, then offers to copy, edit or save it
@MainActor
final class ScreenSnipper: NSObject {
    enum Status { case off, needsPermission, shortcutTaken, on }

    var onChange: (() -> Void)?
    let editors = SnipEditors()

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }
    private(set) var status = Status.off

    private enum Keys {
        static let enabled = "snipScreen"
    }
    private enum Choice: Int { case copy, edit, save }

    private static let screenRecordingSettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    private var hotKey: HotKey?
    private var capture: SnipCapture?
    /// The snip in the open menu
    private var offered: Snip?
    /// The app you were in when you pressed ⌃⌥P, which gets the focus back
    private var previousApp: NSRunningApplication?

    func start() { refresh() }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        // macOS's own dialog, pointing to Privacy & Security → Screen & System Audio Recording. It shows once per app.
        if enabled, !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        refresh()
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(Self.screenRecordingSettings)
    }

    /// Matches the shortcut and status to the switch and the permission. A running app keeps its old answer about the
    /// permission until it restarts, which is why macOS offers Quit & Reopen once it's allowed.
    func refresh() {
        let next: Status
        if !isEnabled {
            next = .off
        } else if !CGPreflightScreenCaptureAccess() {
            next = .needsPermission
        } else if hotKey == nil, !register() {
            next = .shortcutTaken
        } else {
            next = .on
        }
        if next != .on { unregister() }
        guard next != status else { return }
        status = next
        snipLogger.notice("Screen snipping: \(String(describing: next), privacy: .public)")
        onChange?()
    }

    private func register() -> Bool {
        hotKey = HotKeys.register(kVK_ANSI_P, controlKey | optionKey) { [weak self] in self?.pressed() }
        if hotKey == nil { snipLogger.error("Another app is using ⌃⌥P") }
        return hotKey != nil
    }

    private func unregister() {
        if let hotKey { HotKeys.unregister(hotKey) }
        hotKey = nil
    }

    private func pressed() {
        guard capture == nil, offered == nil else { return }  // one at a time
        guard CGPreflightScreenCaptureAccess() else { return refresh() }  // taken away since
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        let clipboard = NSPasteboard.general.changeCount
        capture = SnipCapture { [weak self] outcome in self?.captured(outcome, clipboard: clipboard) }
    }

    private func captured(_ outcome: SnipCapture.Outcome, clipboard: Int) {
        capture = nil
        switch outcome {
        case .taken(let snip):
            snipLogger.notice("Took a snip, \(snip.image.width) × \(snip.image.height) pixels")
            offer(snip)
        case .cancelled:
            // Holding ⌃ while selecting is screencapture's shortcut for the clipboard, so there's no file
            let pasteboard = NSPasteboard.general
            if pasteboard.changeCount != clipboard,
               let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff), let snip = Snip(data: data) {
                snipLogger.notice("Took a snip by way of the clipboard, \(snip.image.width) × \(snip.image.height) pixels")
                offer(snip)
            } else {
                snipLogger.notice("Snip cancelled")
            }
        case .failed(let reason):
            snipLogger.error("Couldn't snip: \(reason, privacy: .public)")
            Alert.show("Couldn't take the snip", reason)
            handBackFocus()
        }
    }

    /// The three choices, at the pointer, which is where the selection ended. The snip on top, as a thumbnail.
    private func offer(_ snip: Snip) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let preview = NSMenuItem()
        preview.image = Self.thumbnail(of: snip)
        preview.isEnabled = false
        menu.addItem(preview)
        menu.addItem(.separator())
        for (title, choice) in [("Copy to Clipboard", Choice.copy), ("Open in Editor", .edit), ("Save…", .save)] {
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = choice.rawValue
            menu.addItem(item)
        }
        offered = snip
        // Without activating Yafie, so the app you were in keeps the focus
        if !menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) {
            offered = nil
            snipLogger.notice("Snip thrown away")
            handBackFocus()
        }
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard let snip = offered, let choice = Choice(rawValue: item.tag) else { return }
        offered = nil
        // Once the menu's tracking has unwound
        Task { @MainActor in act(on: snip, choice) }
    }

    private func act(on snip: Snip, _ choice: Choice) {
        switch choice {
        case .copy:
            if SnipOutput.copy(snip.image, scale: snip.scale) { snipLogger.notice("Copied the snip") }
            handBackFocus()
        case .edit:
            editors.open(snip, returningTo: previousApp)
            previousApp = nil
        case .save:
            SnipOutput.save(snip.image, scale: snip.scale, name: snip.name, from: nil) { [weak self] _ in
                self?.handBackFocus()
            }
        }
    }

    /// So ⌘V pastes where you were
    private func handBackFocus() {
        if NSApp.isActive, !editors.isOpen { NSApp.handFocus(back: previousApp) }
        previousApp = nil
    }

    /// At most 200 × 120 points
    private static func thumbnail(of snip: Snip) -> NSImage {
        let fit = min(1, 200 / snip.size.width, 120 / snip.size.height)
        let size = NSSize(width: max(1, (snip.size.width * fit).rounded()), height: max(1, (snip.size.height * fit).rounded()))
        return NSImage(cgImage: snip.image, size: size)
    }
}

/// One run of macOS's screenshot tool: the ⌘⇧4 selection, with Space for a window and Esc to cancel. It writes the
/// snip to a file of Yafie's, which is read, then deleted.
@MainActor
final class SnipCapture {
    enum Outcome {
        case taken(Snip)
        case cancelled
        case failed(String)
    }

    /// What runs: macOS's tool, unless a test stands in. The file to write goes last.
    struct Tool {
        var executable: URL
        var arguments: [String]

        /// -i selects, -o leaves the shadow off window snips, -x the sound. Without -r, the PNG records the dpi.
        static let screencapture = Tool(executable: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                                        arguments: ["-i", "-o", "-x"])
    }

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("yafie-snip-\(UUID().uuidString).png")
    private let process = Process()
    private let done: @MainActor (Outcome) -> Void

    init(_ tool: Tool = .screencapture, done: @escaping @MainActor (Outcome) -> Void) {
        self.done = done
        process.executableURL = tool.executable
        process.arguments = tool.arguments + [file.path]
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
        do {
            try process.run()
        } catch {
            let reason = error.localizedDescription
            Task { @MainActor in done(.failed(reason)) }
        }
    }

    /// No file means you cancelled, so this checks for the file, not the exit status
    private func finish() {
        defer { try? FileManager.default.removeItem(at: file) }
        guard FileManager.default.fileExists(atPath: file.path) else { return done(.cancelled) }
        guard let data = try? Data(contentsOf: file), let snip = Snip(data: data) else {
            return done(.failed("The snip couldn't be read."))
        }
        done(.taken(snip))
    }
}

/// Copying and saving snips, for the menu and the editor
@MainActor
enum SnipOutput {
    private static let folderKey = "snipFolder"

    /// PNG, plus TIFF for apps that only read that
    @discardableResult
    static func copy(_ image: CGImage, scale: CGFloat) -> Bool {
        guard let png = SnipRenderer.data(image, scale: scale) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = SnipRenderer.data(image, scale: scale, type: .tiff) { pasteboard.setData(tiff, forType: .tiff) }
        return true
    }

    /// A Save dialog: a sheet on the editor's window, or on its own from the menu. Calls back with whether it saved.
    static func save(_ image: CGImage, scale: CGFloat, name: String, from window: NSWindow?,
                     then done: @escaping @MainActor (Bool) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = name + ".png"
        panel.directoryURL = folder
        panel.canCreateDirectories = true
        // ⌘C, ⌘V and the like in the name field come from the Edit menu, which Yafie only has while an editor is open
        let borrowed = NSApp.mainMenu == nil ? SnipMenu.make() : nil
        if let borrowed { NSApp.mainMenu = borrowed }
        let finish = { (response: NSApplication.ModalResponse) in
            if let borrowed, NSApp.mainMenu === borrowed { NSApp.mainMenu = nil }
            guard response == .OK, let url = panel.url else { return done(false) }
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: folderKey)
            guard let png = SnipRenderer.data(image, scale: scale) else {
                Alert.show("Couldn't save the snip", "It couldn't be made into a PNG.")
                return done(false)
            }
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                snipLogger.error("Couldn't save a snip: \(error.localizedDescription, privacy: .public)")
                Alert.show("Couldn't save the snip", error.localizedDescription)
                return done(false)
            }
            snipLogger.notice("Saved a snip")
            done(true)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            NSApp.activateRegardless()
            panel.begin(completionHandler: finish)
        }
    }

    /// Where you last saved one, or the Desktop, where macOS saves screenshots
    private static var folder: URL? {
        if let path = UserDefaults.standard.string(forKey: folderKey), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }
}
