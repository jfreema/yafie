import AppKit
import ApplicationServices

/// What the pointer is on in the Dock. The Dock selects the icon under the pointer and tells Accessibility observers
/// each time that changes, which is also how DockDoor finds it. The Dock is asked on a queue of its own, with a
/// timeout, since the main thread also runs lid sleep.
final class DockWatcher: @unchecked Sendable {
    enum Hover: Equatable, Sendable {
        /// The pointer left the Dock
        case nothing
        /// Something other than an open app, like a folder, the Trash or an app that isn't open
        case otherIcon
        /// An open app's icon
        case app(App)
    }

    struct App: Equatable, Sendable {
        /// The app the icon opens
        var bundle: URL
        var bundleID: String?
        /// In Accessibility's coordinates: from the top left of the main display, y down
        var icon: CGRect
    }

    static let dockBundleID = "com.apple.dock"

    private let onChange: @MainActor @Sendable (Hover) -> Void
    private let queue = DispatchQueue(label: "yafie.dock")
    // Only touched on the queue
    private var observer: AXObserver?
    private var list: AXUIElement?
    private var last: Hover?
    /// Counts starts and stops, so a retry from an earlier start gives up
    private var generation = 0

    /// - Parameter onChange: called on the main thread
    init(onChange: @escaping @MainActor @Sendable (Hover) -> Void) {
        self.onChange = onChange
    }

    /// Starts watching, or starts over with a Dock that restarted
    func start() {
        queue.async {
            self.generation += 1
            self.attach(self.generation, attempt: 1)
        }
    }

    func stop() {
        queue.async {
            self.generation += 1
            self.detach()
        }
    }

    private func attach(_ generation: Int, attempt: Int) {
        guard generation == self.generation else { return }
        detach()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first
        else { return retry(generation, attempt) }
        let pid = dock.processIdentifier
        // Its icons are in a list, which it may not have yet while it starts
        guard let children = value(AXUIElementCreateApplication(pid), kAXChildrenAttribute) as? [AXUIElement],
              let list = children.first(where: { value($0, kAXRoleAttribute) as? String == kAXListRole })
        else { return retry(generation, attempt) }
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<DockWatcher>.fromOpaque(refcon).takeUnretainedValue().selectionChanged()
        }, &created) == .success, let observer = created,
              AXObserverAddNotification(observer, list, kAXSelectedChildrenChangedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success
        else { return retry(generation, attempt) }
        // Its events come on the main thread, which hands each to the queue
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = observer
        self.list = list
        previewLogger.notice("Watching the Dock")
    }

    private func retry(_ generation: Int, _ attempt: Int) {
        guard attempt < 10 else { return previewLogger.error("Couldn't watch the Dock") }
        queue.asyncAfter(deadline: .now() + 1) { self.attach(generation, attempt: attempt + 1) }
    }

    private func detach() {
        guard let observer else { return }
        if let list { AXObserverRemoveNotification(observer, list, kAXSelectedChildrenChangedNotification as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
        list = nil
        last = nil
    }

    private func selectionChanged() {
        queue.async {
            guard let list = self.list else { return }
            let hover = self.hover(in: list)
            guard hover != self.last else { return }
            self.last = hover
            let onChange = self.onChange
            DispatchQueue.main.async { MainActor.assumeIsolated { onChange(hover) } }
        }
    }

    private func hover(in list: AXUIElement) -> Hover {
        guard let selected = value(list, kAXSelectedChildrenAttribute) as? [AXUIElement], let item = selected.first
        else { return .nothing }
        guard value(item, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
              value(item, "AXIsApplicationRunning") as? Bool != false,
              let bundle = value(item, kAXURLAttribute) as? URL else { return .otherIcon }
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let position = value(item, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID() {
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        }
        if let extent = value(item, kAXSizeAttribute), CFGetTypeID(extent) == AXValueGetTypeID() {
            AXValueGetValue(extent as! AXValue, .cgSize, &size)
        }
        return .app(App(bundle: bundle, bundleID: Bundle(url: bundle)?.bundleIdentifier,
                        icon: CGRect(origin: origin, size: size)))
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw
    }
}
