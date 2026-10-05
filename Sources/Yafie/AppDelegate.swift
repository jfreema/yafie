import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = LidAwakeController()
    private let updater = Updater()
    private let snapper = WindowSnapper()
    private let snipper = ScreenSnipper()
    private lazy var tuner: TunerWindowController = {
        let tuner = TunerWindowController()
        tuner.onLoudnessChange = { [weak self] in self?.updateIcon() }
        return tuner
    }()
    private var statusItem: NSStatusItem?
    private var signalSources: [any DispatchSourceSignal] = []
    /// Switches stay put when flipped, so the open menu updates in place
    private var openMenu: OpenMenu?
    /// Alerts and prompts wait for the menu to close
    private var afterMenuCloses: (@MainActor () -> Void)?
    /// A termination signal quits without asking about unsaved snips
    private var isQuittingForSignal = false

    private struct OpenMenu {
        let summary: NSMenuItem
        let stayAwake: ToggleRow
        let online: ToggleRow
        let action: NSMenuItem
        let snap: ToggleRow
        let thirds: ToggleRow
        let snapAction: NSMenuItem
        let snip: ToggleRow
        let snipAction: NSMenuItem
        let login: ToggleRow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        // Otherwise the switch rows, which have no action, would be dimmed
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        controller.onChange = { [weak self] in
            self?.updateIcon()
            self?.refreshMenu()
        }
        controller.start()
        snapper.onChange = { [weak self] in self?.refreshMenu() }
        snapper.start()
        snipper.onChange = { [weak self] in self?.refreshMenu() }
        snipper.start()
        updateIcon()
        quitOnTerminationSignals()
        // A second copy asks this one to speak up
        DistributedNotificationCenter.default().addObserver(forName: Yafie.showMenuNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showMenu() }
        }
        #if DEBUG
        // Test hooks: Yafie --update-now, Yafie --tuner, Yafie --snip-editor <image file>
        let arguments = CommandLine.arguments
        if arguments.contains("--update-now") { updater.checkForUpdates(askFirst: false) }
        if arguments.contains("--tuner") { tuner.show() }
        if let index = arguments.firstIndex(of: "--snip-editor"), arguments.indices.contains(index + 1),
           let data = FileManager.default.contents(atPath: arguments[index + 1]), let snip = Snip(data: data) {
            snipper.editors.open(snip, returningTo: nil)
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    /// Opened again from Finder, or its Dock icon clicked while an editor is open
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Updater.isStale {
            logger.notice("A different version was installed, restarting")
            Updater.relaunch()
        } else if snipper.editors.isOpen {
            snipper.editors.bringForward()
        } else {
            showMenu()
        }
        return false
    }

    /// Snips with shapes that haven't been copied or saved get a chance first
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = snipper.editors.unsaved
        guard unsaved > 0, !isQuittingForSignal else { return .terminateNow }
        NSApp.activateRegardless()
        let alert = NSAlert()
        alert.messageText = unsaved == 1 ? "Quit without saving your snip?" : "Quit without saving \(unsaved) snips?"
        alert.informativeText = "Shapes you haven't copied or saved will be lost."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    private func showMenu() {
        // After the Apple event returns
        DispatchQueue.main.async { [weak self] in self?.statusItem?.button?.performClick(nil) }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        // The permissions may have changed in System Settings
        snapper.refresh()
        snipper.refresh()
        menu.removeAllItems()
        let summary = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())

        let stayAwake = ToggleRow("Stay Awake with Lid Closed While Plugged In") { [weak self] on in
            self?.setStayAwake(on)
        }
        let online = ToggleRow("Only While Connected to the Internet", indented: true) { [weak self] on in
            self?.controller.setRequiresInternet(on)
        }
        menu.addItem(viewItem(stayAwake))
        menu.addItem(viewItem(online))
        // Sleep Now, Finish Setup… or Turn Sleep Back On…, when the status calls for one
        let action = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        action.target = self
        menu.addItem(action)

        menu.addItem(.separator())
        let snap = ToggleRow("Snap Windows with ⌃⌥ Arrow Keys") { [weak self] on in self?.setSnapWindows(on) }
        let thirds = ToggleRow("Snap to Thirds on External Displays", indented: true) { [weak self] on in
            self?.snapper.setUsesThirds(on)
        }
        menu.addItem(viewItem(snap))
        menu.addItem(viewItem(thirds))
        // Allow Window Snapping…, or why the shortcut didn't take, when the status calls for one
        let snapAction = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        snapAction.target = self
        menu.addItem(snapAction)

        menu.addItem(.separator())
        let snip = ToggleRow("Snip the Screen with ⌃⌥P") { [weak self] on in self?.setSnipScreen(on) }
        menu.addItem(viewItem(snip))
        // Allow Screen Snipping…, or why the shortcut didn't take, when the status calls for one
        let snipAction = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        snipAction.target = self
        menu.addItem(snipAction)

        menu.addItem(.separator())
        menu.addItem(item("Guitar Tuner…", #selector(openTuner)))

        menu.addItem(.separator())
        let login = ToggleRow("Open at Login") { [weak self] on in self?.setOpenAtLogin(on) }
        menu.addItem(viewItem(login))
        menu.addItem(.separator())
        menu.addItem(item("About Yafie", #selector(showAbout)))
        if updater.isBusy {
            let busy = NSMenuItem(title: "Checking for Updates…", action: nil, keyEquivalent: "")
            busy.isEnabled = false
            menu.addItem(busy)
        } else {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Yafie",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        openMenu = OpenMenu(summary: summary, stayAwake: stayAwake, online: online, action: action,
                            snap: snap, thirds: thirds, snapAction: snapAction, snip: snip, snipAction: snipAction,
                            login: login)
        refreshMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        openMenu = nil
        guard let work = afterMenuCloses else { return }
        afterMenuCloses = nil
        // Once the menu's tracking has unwound
        Task { @MainActor in work() }
    }

    /// Matches the open menu to the current state
    private func refreshMenu() {
        guard let menu = openMenu else { return }
        let status = controller.status
        menu.summary.title = status.summary
        menu.stayAwake.isOn = controller.isEnabled
        menu.online.isOn = controller.requiresInternet
        // Only means something while the main switch is on
        menu.online.isEnabled = controller.isEnabled
        menu.login.isOn = SMAppService.mainApp.status == .enabled

        let action: (title: String, selector: Selector)? = switch status {
        case .active: ("Sleep Now", #selector(sleepNow))
        case .needsSetup: ("Finish Setup…", #selector(finishSetup))
        case .restoreFailed: ("Turn Sleep Back On…", #selector(retryRestore))
        case .off, .waitingForPower, .waitingForInternet: nil
        }
        menu.action.title = action?.title ?? ""
        menu.action.action = action?.selector
        menu.action.isHidden = action == nil

        menu.snap.isOn = snapper.isEnabled
        menu.thirds.isOn = snapper.usesThirds
        menu.thirds.isEnabled = snapper.isEnabled
        switch snapper.status {
        case .needsPermission:
            menu.snapAction.title = "Allow Window Snapping…"
            menu.snapAction.action = #selector(allowWindowSnapping)
            menu.snapAction.isEnabled = true
        case .shortcutTaken:
            menu.snapAction.title = "Another app is using a ⌃⌥ arrow key"
            menu.snapAction.action = nil
            menu.snapAction.isEnabled = false
        case .off, .on:
            break
        }
        menu.snapAction.isHidden = snapper.status != .needsPermission && snapper.status != .shortcutTaken

        menu.snip.isOn = snipper.isEnabled
        switch snipper.status {
        case .needsPermission:
            menu.snipAction.title = "Allow Screen Snipping…"
            menu.snipAction.action = #selector(allowScreenSnipping)
            menu.snipAction.isEnabled = true
        case .shortcutTaken:
            menu.snipAction.title = "Another app is using ⌃⌥P"
            menu.snipAction.action = nil
            menu.snipAction.isEnabled = false
        case .off, .on:
            break
        }
        menu.snipAction.isHidden = snipper.status != .needsPermission && snipper.status != .shortcutTaken
    }

    private func closeMenu(then work: @escaping @MainActor () -> Void) {
        afterMenuCloses = work
        statusItem?.menu?.cancelTracking()
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func viewItem(_ row: ToggleRow) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = row
        return item
    }

    private func setStayAwake(_ on: Bool) {
        if on, controller.needsPasswordToEnable {
            // The password prompt needs the screen
            closeMenu { [weak self] in self?.controller.setEnabled(true) }
        } else {
            controller.setEnabled(on)
        }
    }

    private func setSnapWindows(_ on: Bool) {
        if on, !AXIsProcessTrusted() {
            // macOS's permission dialog needs the screen
            closeMenu { [weak self] in self?.snapper.setEnabled(true) }
        } else {
            snapper.setEnabled(on)
        }
    }

    private func setSnipScreen(_ on: Bool) {
        if on, !CGPreflightScreenCaptureAccess() {
            // macOS's permission dialog needs the screen
            closeMenu { [weak self] in self?.snipper.setEnabled(true) }
        } else {
            snipper.setEnabled(on)
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            try on ? service.register() : service.unregister()
        } catch {
            let message = error.localizedDescription
            closeMenu { Alert.show("Couldn't change Open at Login", message) }
        }
        if service.status == .requiresApproval {
            closeMenu { SMAppService.openSystemSettingsLoginItems() }
        }
        refreshMenu()
    }

    @objc private func checkForUpdates() { updater.checkForUpdates() }

    @objc func showAbout() {
        NSApp.activate()
        // Empty build number drops the "(1)"
        NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: Bundle.main.shortVersion, .version: ""])
    }
    @objc private func openTuner() { tuner.show() }
    @objc private func allowWindowSnapping() { snapper.openAccessibilitySettings() }
    @objc private func allowScreenSnipping() { snipper.openScreenRecordingSettings() }
    @objc private func sleepNow() { controller.sleepNow() }
    @objc private func finishSetup() { controller.finishSetup() }
    @objc private func retryRestore() { controller.retryRestore() }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        // A colored icon says the tuner is open, and how loud a sound it hears
        if let loudness = tuner.loudness {
            let image = loudness.icon
            image?.accessibilityDescription = "Tuner open, \(loudness.spoken)"
            button.image = image
            button.appearsDisabled = false
            button.toolTip = "Yafie: Tuner is open"
            return
        }
        let status = controller.status
        let image = status.icon
        image?.isTemplate = true  // drawn in the menu bar's color
        image?.accessibilityDescription = status.summary
        button.image = image
        // Dimmed but still clickable
        button.appearsDisabled = status == .off
        button.toolTip = "Yafie: \(status.summary)"
    }

    /// Clean quit restores sleep
    private func quitOnTerminationSignals() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.isQuittingForSignal = true
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

private extension LidAwakeController.Status {
    var summary: String {
        switch self {
        case .off: "Off: closing the lid sleeps your Mac"
        case .waitingForPower: "On battery: sleeps normally until plugged in"
        case .waitingForInternet: "Offline: sleeps normally until back online"
        case .active: "Plugged in: stays awake with the lid closed"
        case .needsSetup: "Needs your password once to finish setup"
        case .restoreFailed: "Couldn't turn sleep back on"
        }
    }

    /// The icon, filled while it keeps the Mac awake
    var icon: NSImage? {
        switch self {
        case .off, .waitingForPower, .waitingForInternet: NSImage(named: "MenuIconOutline")
        case .active: NSImage(named: "MenuIcon")
        case .needsSetup, .restoreFailed: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        }
    }
}

private extension LoudnessMeter.Loudness {
    /// The filled icon: green while it's quiet or soft, then bright yellow, orange or red
    var icon: NSImage? {
        guard let glyph = NSImage(named: "MenuIcon") else { return nil }
        let color: NSColor = switch self {
        case .quiet, .soft: .systemGreen
        case .medium: .systemYellow
        case .loud: .systemOrange
        case .veryLoud: .systemRed
        }
        let image = NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false  // keeps its color
        return image
    }

    var spoken: String {
        switch self {
        case .quiet: "quiet"
        case .soft: "hearing a soft sound"
        case .medium: "hearing a medium sound"
        case .loud: "hearing a loud sound"
        case .veryLoud: "hearing a very loud sound"
        }
    }
}

@MainActor
enum Alert {
    static func show(_ title: String, _ message: String) {
        NSApp.activateRegardless()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    static func confirm(_ title: String, _ message: String, button: String) -> Bool {
        NSApp.activateRegardless()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension NSApplication {
    /// Comes to the front, over the app you're in. Since macOS 14, activate() is only a request, and macOS turns it
    /// down when what Yafie shows comes after a wait, like an update check, or from a pop-up menu, like a snip's
    /// choices. Then an alert opens behind the app you're in and seems stuck. This one isn't a request.
    func activateRegardless() {
        activate(ignoringOtherApps: true)
    }

    /// Gives the focus back to the app you were in, the cooperative way: Yafie yields it, then asks for the hand-off
    func handFocus(back app: NSRunningApplication?) {
        guard let app, !app.isTerminated else { return }
        yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }
}
