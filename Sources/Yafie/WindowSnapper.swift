import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

private let snapLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "yafie", category: "snap")

/// What a shortcut asks of the frontmost window
enum SnapAction: Sendable {
    /// ⌃⌥← and ⌃⌥→: between columns and displays
    case move(SnapLayout.Direction)
    /// ⌃⌥↑: wider, up to the whole display
    case expand
    /// ⌃⌥↓: around the display's quarters or sixths
    case cycle
}

/// ⌃⌥← and ⌃⌥→ throw the frontmost window between columns and displays, ⌃⌥↑ widens it, and ⌃⌥↓ takes it around the
/// display's quarters or sixths
@MainActor
final class WindowSnapper {
    enum Status { case off, needsPermission, shortcutTaken, on }

    var onChange: (() -> Void)?

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }
    /// Three columns instead of two on external displays
    private(set) var usesThirds = UserDefaults.standard.bool(forKey: Keys.thirds) {
        didSet { UserDefaults.standard.set(usesThirds, forKey: Keys.thirds) }
    }
    private(set) var status = Status.off

    private enum Keys {
        static let enabled = "snapWindows"
        static let thirds = "snapThirds"
    }
    private static let accessibilitySettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private var hotKeys: [HotKey] = []
    /// Watches for the permission while it's missing
    private var permissionTimer: Timer?
    private let mover = WindowMover()

    func start() { refresh() }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled, !AXIsProcessTrusted() {
            // macOS's own dialog, pointing to Privacy & Security → Accessibility. The key is
            // kAXTrustedCheckOptionPrompt's value: Swift 6 won't read that C global.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        refresh()
    }

    func setUsesThirds(_ thirds: Bool) {
        usesThirds = thirds
        onChange?()
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(Self.accessibilitySettings)
    }

    /// Matches the hotkeys and status to the switch and the permission
    func refresh() {
        let next: Status
        if !isEnabled {
            next = .off
        } else if !AXIsProcessTrusted() {
            next = .needsPermission
        } else if hotKeys.isEmpty, !register() {
            next = .shortcutTaken
        } else {
            next = .on
        }
        if next != .on { unregister() }
        if next == .needsPermission { watchForPermission() } else { stopWatching() }
        guard next != status else { return }
        status = next
        snapLogger.notice("Window snapping: \(String(describing: next), privacy: .public)")
        onChange?()
    }

    private func pressed(_ action: SnapAction) {
        guard AXIsProcessTrusted() else { return refresh() }  // taken away since
        guard let app = NSWorkspace.shared.frontmostApplication, let main = NSScreen.screens.first else { return }
        let displays = NSScreen.screens.map { screen in
            // Thirds only on external displays, since a MacBook's own screen is too narrow for them
            SnapLayout.Display(frame: screen.frame, visible: screen.visibleFrame,
                               columns: usesThirds && !screen.isBuiltIn ? 3 : 2)
        }
        mover.snap(app.processIdentifier, action, on: displays, mainHeight: main.frame.maxY)
    }

    /// False if another app holds any of the shortcuts
    private func register() -> Bool {
        let keys: [(Int, SnapAction)] = [(kVK_LeftArrow, .move(.left)), (kVK_RightArrow, .move(.right)),
                                         (kVK_UpArrow, .expand), (kVK_DownArrow, .cycle)]
        for (key, action) in keys {
            guard let hotKey = HotKeys.register(key, controlKey | optionKey, action: { [weak self] in
                self?.pressed(action)
            }) else {
                snapLogger.error("Another app is using a ⌃⌥ arrow key")
                unregister()
                return false
            }
            hotKeys.append(hotKey)
        }
        return true
    }

    private func unregister() {
        for hotKey in hotKeys { HotKeys.unregister(hotKey) }
        hotKeys.removeAll()
    }

    private func watchForPermission() {
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)  // fires while the menu is open
        permissionTimer = timer
    }

    private func stopWatching() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }
}

/// Moves other apps' windows through the Accessibility API, on a queue of its own. Each call is a message to the
/// other app, which may be hung, and the main thread also runs lid sleep.
final class WindowMover: @unchecked Sendable {
    private let queue = DispatchQueue(label: "yafie.snapper")
    /// Recent snaps, newest first: the column each window was sent to and the frame it ended up with.
    /// Only touched on the queue.
    private var recent: [(window: AXUIElement, target: CGRect, result: CGRect)] = []

    init() {
        // A hung app can't hold a snap up for long
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
    }

    func snap(_ pid: pid_t, _ action: SnapAction, on displays: [SnapLayout.Display], mainHeight: CGFloat) {
        queue.async { self.snapNow(pid, action, displays, mainHeight) }
    }

    private func snapNow(_ pid: pid_t, _ action: SnapAction, _ displays: [SnapLayout.Display], _ mainHeight: CGFloat) {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString,
                                            &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return }
        let window = focused as! AXUIElement
        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
           (fullScreen as? Bool) == true { return }
        guard let frame = frame(of: window, mainHeight) else { return }

        let last = recent.first { CFEqual($0.window, window) }
        let lastTarget = last.flatMap { $0.result.isClose(to: frame, tolerance: 2) ? $0.target : nil }
        let target = switch action {
        case .move(let direction):
            SnapLayout.target(for: frame, on: displays, direction: direction, lastTarget: lastTarget)
        case .expand:
            SnapLayout.expanded(frame, on: displays, lastTarget: lastTarget)
        case .cycle:
            SnapLayout.cycled(frame, on: displays, lastTarget: lastTarget)
        }
        guard let target,
              let display = displays.first(where: { $0.visible.contains(CGPoint(x: target.midX, y: target.midY)) })
        else { return }
        let result = apply(target, to: window, within: display.visible, mainHeight) ?? target
        recent.removeAll { CFEqual($0.window, window) }
        recent.insert((window, target, result), at: 0)
        if recent.count > 8 { recent.removeLast() }
    }

    /// Returns where the window ended up
    private func apply(_ column: CGRect, to window: AXUIElement, within area: CGRect, _ mainHeight: CGFloat) -> CGRect? {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable)
        // Size, move, size again: an app may refuse a size that doesn't fit the old display until it has moved
        if settable.boolValue { set(window, size: column.size) }
        set(window, frame: column, mainHeight)
        if settable.boolValue { set(window, size: column.size) }
        guard let result = frame(of: window, mainHeight) else { return nil }
        if result.size.isClose(to: column.size) { return result }
        // Fixed size, or kept wider than the column
        set(window, frame: SnapLayout.place(result.size, in: column, on: area), mainHeight)
        return frame(of: window, mainHeight)
    }

    private func frame(of window: AXUIElement, _ mainHeight: CGFloat) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = value(of: window, kAXPositionAttribute), AXValueGetValue(position, .cgPoint, &origin),
              let extent = value(of: window, kAXSizeAttribute), AXValueGetValue(extent, .cgSize, &size) else { return nil }
        return SnapLayout.flipped(CGRect(origin: origin, size: size), mainHeight: mainHeight)
    }

    private func value(of element: AXUIElement, _ attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return (raw as! AXValue)
    }

    /// Moves the window's top left to the frame's
    private func set(_ window: AXUIElement, frame: CGRect, _ mainHeight: CGFloat) {
        var origin = SnapLayout.flipped(frame, mainHeight: mainHeight).origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    private func set(_ window: AXUIElement, size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }
}

private extension NSScreen {
    /// The Mac's own screen, like a MacBook's
    var isBuiltIn: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    }
}
