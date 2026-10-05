import AppKit

@main
@MainActor
enum Yafie {
    static let showMenuNotification = Notification.Name("io.github.jfreema.yafie.showMenu")

    static func main() {
        // Watchdog and tuner listener skip the dupe check
        if CommandLine.arguments.contains(Watchdog.argument) {
            Watchdog.run()
            return
        }
        if CommandLine.arguments.contains(TunerListener.argument) {
            TunerListener.run()
        }

        // Two copies would fight
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .first(where: { $0.processIdentifier != me }) {
            guard replaces(other), quitAndWait(other) else {
                // Else opening it looks like nothing happened
                DistributedNotificationCenter.default().postNotificationName(showMenuNotification, object: nil,
                                                                             userInfo: nil, deliverImmediately: true)
                return
            }
            logger.notice("Took over from the copy that was running")
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// An update installed by hand
    private static func replaces(_ other: NSRunningApplication) -> Bool {
        let mine = Bundle.main.bundleURL.standardizedFileURL
        guard let theirs = other.bundleURL?.standardizedFileURL else { return false }
        // macOS only starts a second copy from the same place if it was replaced on disk
        if theirs == mine { return true }
        let info = NSDictionary(contentsOf: theirs.appendingPathComponent("Contents/Info.plist"))
        guard let version = info?["CFBundleShortVersionString"] as? String else { return false }
        return Bundle.main.shortVersion.compare(version, options: .numeric) == .orderedDescending
    }

    /// Quitting restores sleep first
    private static func quitAndWait(_ other: NSRunningApplication) -> Bool {
        guard other.terminate() else { return false }
        let deadline = Date().addingTimeInterval(10)
        while kill(other.processIdentifier, 0) == 0 {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }
}
