import AppKit
import ApplicationServices
import ScreenCaptureKit

/// The windows App Preview shows, through the Accessibility API on a queue of its own. Each call is a message to the
/// other app, which may be hung, and the main thread also runs lid sleep.
final class AppWindows: @unchecked Sendable {
    /// Its element is only used on the queue
    struct Window: @unchecked Sendable {
        let element: AXUIElement
        let pid: pid_t
        /// The window server's number for it, 0 if unknown
        let id: CGWindowID
        let title: String
        let size: CGSize
        let isMinimized: Bool
        /// Its title bar's red button. Nil for a window that can't be closed.
        let closeButton: AXUIElement?

        /// The same window, listed again
        func isSame(as other: Window) -> Bool {
            id != 0 && other.id != 0 ? id == other.id : CFEqual(element, other.element)
        }
    }

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// A private call that window managers have relied on for years, and the only sure way to match a window to its
    /// picture: two Chrome windows can have the same frame and title. Without it, there are no pictures.
    private static let getWindow: GetWindow? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    private let queue = DispatchQueue(label: "yafie.preview")

    init() {
        // A hung app can't hold the preview up for long
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
    }

    /// The apps' windows on this desktop, minimized ones too, oldest first so they keep their places
    func list(_ pids: [pid_t], then done: @escaping @MainActor ([Window]) -> Void) {
        queue.async {
            let windows = pids.flatMap(self.windows(of:)).sorted { $0.order < $1.order }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(windows) } }
        }
    }

    /// Brings the window to the front, out of the Dock if it's minimized, and makes its app the one you're in
    func focus(_ window: Window, then done: @escaping @MainActor () -> Void) {
        queue.async {
            if window.isMinimized {
                AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(window.pid), kAXFrontmostAttribute as CFString,
                                         kCFBooleanTrue)
            AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }

    /// Presses its close button, as a click on it would. The app may close it, or ask about unsaved changes first.
    func close(_ window: Window, then done: @escaping @MainActor () -> Void) {
        queue.async {
            if let button = window.closeButton { AXUIElementPerformAction(button, kAXPressAction as CFString) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }

    /// Standard windows only, which leaves out palettes, panels and the like
    private func windows(of pid: pid_t) -> [Window] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString,
                                            &raw) == .success,
              let elements = raw as? [AXUIElement] else { return [] }
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXSizeAttribute,
                          kAXMinimizedAttribute, kAXCloseButtonAttribute] as CFArray
        return elements.compactMap { element in
            // One message per window
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &raw) == .success,
                  let values = raw as? [AnyObject], values.count == 6,
                  values[0] as? String == kAXWindowRole, values[1] as? String == kAXStandardWindowSubrole,
                  CFGetTypeID(values[3]) == AXValueGetTypeID() else { return nil }
            var size = CGSize.zero
            guard AXValueGetValue(values[3] as! AXValue, .cgSize, &size), size.width >= 40, size.height >= 40
            else { return nil }
            var id: CGWindowID = 0
            if Self.getWindow?(element, &id) != .success { id = 0 }
            let closeButton = CFGetTypeID(values[5]) == AXUIElementGetTypeID() ? (values[5] as! AXUIElement) : nil
            return Window(element: element, pid: pid, id: id, title: values[2] as? String ?? "", size: size,
                          isMinimized: values[4] as? Bool ?? false, closeButton: closeButton)
        }
    }
}

private extension AppWindows.Window {
    /// The window server numbers windows as they open. Unknown ones go last.
    var order: CGWindowID { id == 0 ? .max : id }
}

/// Pictures of windows that are on screen, from ScreenCaptureKit. Needs the Screen Recording permission.
enum WindowPictures {
    /// Each picture fits the size, at that many pixels per point
    static func take(_ ids: Set<CGWindowID>, fitting size: CGSize, scale: CGFloat) async -> [CGWindowID: CGImage] {
        guard !ids.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { return [:] }
        var pictures: [CGWindowID: CGImage] = [:]
        for window in content.windows where ids.contains(window.windowID) {
            let fitted = PreviewLayout.fit(window.frame.size, in: CGRect(origin: .zero, size: size)).size
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(fitted.width * scale))
            configuration.height = max(1, Int(fitted.height * scale))
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: window)
            if let picture = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                         configuration: configuration) {
                pictures[window.windowID] = picture
            }
        }
        return pictures
    }
}
