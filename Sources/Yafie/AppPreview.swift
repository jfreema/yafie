import AppKit
import os

let previewLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "yafie", category: "preview")

/// Resting the pointer on an open app's Dock icon shows its windows, and clicking one brings it to the front
@MainActor
final class AppPreview {
    enum Status { case off, needsAccessibility, needsScreenRecording, on }

    var onChange: (() -> Void)?

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }
    private(set) var status = Status.off
    /// Without Screen Recording it still works, with titles but no pictures
    var needsPermission: Bool { status == .needsAccessibility || status == .needsScreenRecording }

    private enum Keys {
        static let enabled = "appPreview"
    }
    private static let accessibilitySettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private static let screenRecordingSettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    /// How long the pointer rests on an icon before the first preview, so sweeping across the Dock shows nothing
    private static let restDelay = Duration.milliseconds(200)
    /// How long it takes to switch to another app's preview. Heading for a far card can cross the next icon.
    private static let switchDelay = Duration.milliseconds(150)
    /// How long the pointer can wander before the preview closes
    private static let leaveDelay: TimeInterval = 0.3
    /// Pictures kept from earlier previews, to show while new ones are taken
    private static let keptPictures = 24

    private lazy var watcher = DockWatcher { [weak self] hover in self?.hovered(hover) }
    private let windows = AppWindows()
    private lazy var panel: PreviewPanel = {
        let panel = PreviewPanel()
        panel.onChoose = { [weak self] index in self?.choose(index) }
        panel.onClose = { [weak self] index in self?.close(index) }
        return panel
    }()
    private var dockObserver: (any NSObjectProtocol)?
    /// Watches for the permission while it's missing
    private var permissionTimer: Timer?

    private var hover = DockWatcher.Hover.nothing
    /// What the panel shows
    private var shown: Shown?
    /// A preview about to be shown
    private var waiting: Task<Void, Never>?
    /// Counts previews, so answers for an earlier one are dropped
    private var request = 0
    private var pointerTimer: Timer?
    /// When the pointer wandered off
    private var leftAt: TimeInterval?
    private var clickMonitor: Any?
    private var pictures: [CGWindowID: CGImage] = [:]
    /// Oldest first
    private var pictureOrder: [CGWindowID] = []

    private struct Shown {
        let app: DockWatcher.App
        /// In AppKit coordinates, at its largest
        let icon: CGRect
        let edge: PreviewLayout.Edge
        let windows: [AppWindows.Window]
    }

    func start() {
        // The Dock starts over when it crashes, or after a change to some of its settings
        dockObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == DockWatcher.dockBundleID else { return }
            MainActor.assumeIsolated { self?.dockRestarted() }
        }
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            if !AXIsProcessTrusted() {
                // macOS's own dialog, pointing to Privacy & Security → Accessibility. The key is
                // kAXTrustedCheckOptionPrompt's value: Swift 6 won't read that C global.
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            // For the pictures. macOS just adds Yafie to its list, switched off.
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        }
        refresh()
    }

    /// The list Yafie still has to be turned on in
    func openSettings() {
        NSWorkspace.shared.open(AXIsProcessTrusted() ? Self.screenRecordingSettings : Self.accessibilitySettings)
    }

    /// Matches the Dock watching and status to the switch and the permissions. As with snips, a running app keeps
    /// its old answer about Screen Recording until it restarts.
    func refresh() {
        let next: Status
        if !isEnabled {
            next = .off
        } else if !AXIsProcessTrusted() {
            next = .needsAccessibility
        } else if !CGPreflightScreenCaptureAccess() {
            next = .needsScreenRecording
        } else {
            next = .on
        }
        if next == .needsAccessibility { watchForPermission() } else { stopWatching() }
        guard next != status else { return }
        let wasWatching = isWatching
        status = next
        if isWatching, !wasWatching { watcher.start() }
        if !isWatching, wasWatching {
            watcher.stop()
            hide()
        }
        previewLogger.notice("App Preview: \(String(describing: next), privacy: .public)")
        onChange?()
    }

    private var isWatching: Bool { status == .on || status == .needsScreenRecording }

    private func dockRestarted() {
        guard isWatching else { return }
        hide()
        watcher.start()
    }

    // MARK: Showing

    private func hovered(_ hover: DockWatcher.Hover) {
        self.hover = hover
        waiting?.cancel()
        // The Dock can still have an icon selected while the pointer is over the panel
        if isOverPanel { return }
        switch hover {
        case .nothing:
            break  // perhaps on the way to the panel, which watchPointer looks after
        case .otherIcon:
            hide()
        case .app(let app):
            leftAt = nil
            if shown?.app.bundle == app.bundle { return }
            let delay = panel.isVisible ? Self.switchDelay : Self.restDelay
            waiting = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, !isOverPanel else { return }
                preview(app)
            }
        }
    }

    private var isOverPanel: Bool { panel.isVisible && panel.frame.contains(NSEvent.mouseLocation) }

    private func preview(_ app: DockWatcher.App) {
        guard let main = NSScreen.screens.first else { return }
        let running = runningApps(app)
        guard !running.isEmpty else { return hide() }
        request += 1
        let request = request
        windows.list(running.map(\.processIdentifier)) { [weak self] found in
            guard let self, request == self.request,
                  case .app(let current) = hover, current.bundle == app.bundle else { return }
            guard !found.isEmpty else { return hide() }
            show(found, of: app, running[0], mainHeight: main.frame.maxY)
        }
    }

    private func show(_ found: [AppWindows.Window], of app: DockWatcher.App, _ running: NSRunningApplication,
                      mainHeight: CGFloat) {
        let edge = PreviewLayout.Edge(orientation: Self.dockSetting("orientation") as? String)
        // At the pointer, if the Dock didn't say where the icon is
        var icon = app.icon.isEmpty ? CGRect(origin: NSEvent.mouseLocation, size: .zero).insetBy(dx: -1, dy: -1)
            : SnapLayout.flipped(app.icon, mainHeight: mainHeight)
        if Self.dockSetting("magnification") as? Bool == true, let largest = Self.dockSetting("largesize") as? Double {
            icon = PreviewLayout.magnified(icon, to: largest, edge: edge)
        }
        let center = CGPoint(x: icon.midX, y: icon.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else { return }
        let placement = PreviewLayout.place(found.count, by: icon, edge: edge, in: screen.visibleFrame)
        let name = running.localizedName ?? ""
        let cards = found.map { window in
            PreviewPanel.Card(title: window.title.isEmpty ? name : window.title, size: window.size,
                              picture: pictures[window.id], isMinimized: window.isMinimized,
                              canClose: window.closeButton != nil)
        }
        panel.show(cards, icon: running.icon, placement: placement)
        shown = Shown(app: app, icon: icon, edge: edge, windows: found)
        previewLogger.debug("Showing \(found.count) windows of \(name, privacy: .public)")
        watchPointer()
        if status == .on, let card = placement.cards.first {
            takePictures(of: found, fitting: PreviewLayout.pictureArea(in: card.size).size,
                         scale: screen.backingScaleFactor)
        }
    }

    private func takePictures(of found: [AppWindows.Window], fitting size: CGSize, scale: CGFloat) {
        let ids = Set(found.map(\.id).filter { $0 != 0 })
        let request = request
        Task { [weak self] in
            let taken = await WindowPictures.take(ids, fitting: size, scale: scale)
            previewLogger.debug("Took \(taken.count) of \(ids.count) pictures")
            guard let self else { return }
            keep(taken)
            guard request == self.request, let shown else { return }
            for (index, window) in shown.windows.enumerated() {
                if let picture = taken[window.id] { panel.setPicture(picture, at: index) }
            }
        }
    }

    private func keep(_ taken: [CGWindowID: CGImage]) {
        for (id, picture) in taken {
            pictures[id] = picture
            pictureOrder.removeAll { $0 == id }
            pictureOrder.append(id)
        }
        while pictureOrder.count > Self.keptPictures { pictures[pictureOrder.removeFirst()] = nil }
    }

    /// An app can run more than once, as with open -n
    private func runningApps(_ app: DockWatcher.App) -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        let running = if let id = app.bundleID {
            NSRunningApplication.runningApplications(withBundleIdentifier: id)
        } else {
            NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL?.standardizedFileURL.path == app.bundle.standardizedFileURL.path
            }
        }
        return running.filter { $0.processIdentifier != me && !$0.isTerminated }
    }

    private static func dockSetting(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, DockWatcher.dockBundleID as CFString)
    }

    // MARK: Closing

    /// The panel closes once the pointer has left the icon, the panel and the way between them, or on a click
    /// anywhere else, like on the icon itself
    private func watchPointer() {
        leftAt = nil
        if pointerTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkPointer() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pointerTimer = timer
        }
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown,
                                                                        .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    private func checkPointer() {
        guard let shown else { return hide() }
        let now = ProcessInfo.processInfo.systemUptime
        if PreviewLayout.keepsOpen(NSEvent.mouseLocation, panel: panel.frame, icon: shown.icon, edge: shown.edge) {
            leftAt = nil
        } else if let leftAt {
            if now - leftAt >= Self.leaveDelay { hide() }
        } else {
            leftAt = now
        }
    }

    private func hide() {
        waiting?.cancel()
        request += 1
        shown = nil
        panel.hide()
        pointerTimer?.invalidate()
        pointerTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func choose(_ index: Int) {
        guard let shown, shown.windows.indices.contains(index) else { return }
        bringForward(shown.windows[index])
    }

    /// Presses the window's close button, then looks again. The rest of the app's windows stay in the panel. If the
    /// window's still open, the app is most likely asking about unsaved changes, so it comes forward to be answered.
    private func close(_ index: Int) {
        guard let shown, shown.windows.indices.contains(index) else { return }
        let window = shown.windows[index]
        let app = shown.app
        request += 1
        let request = request
        windows.close(window) { [weak self] in
            Task {
                // A moment for the app to close it, or to ask first
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, request == self.request else { return }
                self.lookAgain(at: app, after: window)
            }
        }
    }

    private func lookAgain(at app: DockWatcher.App, after closed: AppWindows.Window) {
        guard let main = NSScreen.screens.first else { return }
        let running = runningApps(app)
        let request = request
        windows.list(running.map(\.processIdentifier)) { [weak self] found in
            guard let self, request == self.request, shown?.app.bundle == app.bundle else { return }
            if let open = found.first(where: { $0.isSame(as: closed) }) { return bringForward(open) }
            guard let first = running.first, !found.isEmpty else { return hide() }
            show(found, of: app, first, mainHeight: main.frame.maxY)
        }
    }

    private func bringForward(_ window: AppWindows.Window) {
        hide()
        let app = NSRunningApplication(processIdentifier: window.pid)
        if app?.isHidden == true { app?.unhide() }
        windows.focus(window) {
            // In case the app turned down the Accessibility request to come forward
            _ = app?.activate(options: [])
        }
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
