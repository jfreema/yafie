import AppKit
import CryptoKit

/// Updates from the repo's downloads folder
@MainActor
final class Updater {
    private(set) var isBusy = false

    /// What build.sh --pkg publishes next to the installer
    struct Release: Decodable, Sendable {
        let version: String
        let url: URL
        let sha256: String
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static var feed: URL {
        // Overridable for testing
        if let custom = UserDefaults.standard.string(forKey: "updateFeed"), let url = URL(string: custom) { return url }
        return URL(string: "https://raw.githubusercontent.com/jfreema/yafie/main/downloads/latest.json")!
    }

    /// Replaced on disk since launch
    static var isStale: Bool {
        let info = NSDictionary(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"))
        guard let onDisk = info?["CFBundleShortVersionString"] as? String else { return false }
        return onDisk != Bundle.main.shortVersion
    }

    func checkForUpdates(askFirst: Bool = true) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await check(askFirst: askFirst)
            isBusy = false
        }
    }

    private func check(askFirst: Bool) async {
        let current = Bundle.main.shortVersion
        let release: Release
        do {
            release = try await Self.latestRelease(from: Self.feed)
        } catch {
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            Alert.show("Couldn't check for updates", error.localizedDescription)
            return
        }
        guard release.version.compare(current, options: .numeric) == .orderedDescending else {
            Alert.show("Yafie is up to date", "Version \(current) is the newest.")
            return
        }
        if askFirst {
            guard Alert.confirm("Yafie \(release.version) is available",
                                "You have \(current). Yafie restarts on the new version when it's done.",
                                button: "Update") else { return }
        }
        let app = Bundle.main.bundleURL
        do {
            // Translocated copies run from a read-only folder
            guard !app.path.contains("/AppTranslocation/") else {
                throw Failure("Move Yafie to your Applications folder, open it from there, then try again.")
            }
            guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
                throw Failure("Yafie can't replace itself in \(app.deletingLastPathComponent().path). "
                              + "Download the new version from GitHub instead.")
            }
            try await Self.replace(app, with: release, bundleID: Bundle.main.bundleIdentifier)
        } catch {
            logger.error("Update failed: \(error.localizedDescription, privacy: .public)")
            Alert.show("Couldn't update Yafie", error.localizedDescription)
            return
        }
        logger.notice("Updated to \(release.version, privacy: .public), restarting")
        Self.relaunch()
    }

    nonisolated private static func latestRelease(from feed: URL) async throws -> Release {
        let request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response)
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw Failure("The update information didn't make sense.")
        }
        return release
    }

    /// Download, verify, swap in place
    nonisolated static func replace(_ app: URL, with release: Release, bundleID: String?) async throws {
        let files = FileManager.default
        // Same volume as the app, so the swap is atomic
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? files.removeItem(at: work) }

        let (download, response) = try await URLSession.shared.download(from: release.url)
        let pkg = work.appendingPathComponent("Yafie.pkg")
        try files.moveItem(at: download, to: pkg)
        try checkStatus(response)
        let digest = SHA256.hash(data: try Data(contentsOf: pkg)).map { String(format: "%02x", $0) }.joined()
        // Caches can serve the new version file before the new package
        guard digest == release.sha256.lowercased() else {
            throw Failure("The download didn't match the published version. Try again in a few minutes.")
        }

        // Unpack it instead of running Installer, which would want a password
        let expanded = work.appendingPathComponent("expanded")
        guard Shell.run("/usr/sbin/pkgutil", ["--expand-full", pkg.path, expanded.path], timeout: 60).status == 0,
              let unpacked = findApp(in: expanded) else {
            throw Failure("Couldn't unpack the downloaded installer.")
        }
        let staged = work.appendingPathComponent(app.lastPathComponent)
        try files.moveItem(at: unpacked, to: staged)

        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID,
              info?["CFBundleShortVersionString"] as? String == release.version,
              Shell.run("/usr/bin/codesign", ["--verify", "--strict", staged.path]).status == 0 else {
            throw Failure("The downloaded app didn't check out.")
        }
        _ = try files.replaceItemAt(app, withItemAt: staged)
    }

    /// Lands in <name>.pkg/Payload, and macOS counts .pkg folders as bundles too
    nonisolated private static func findApp(in folder: URL) -> URL? {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walk where url.pathExtension == "app" {
            if url.lastPathComponent == "Yafie.app" { return url }
            walk.skipDescendants()
        }
        return nil
    }

    nonisolated private static func checkStatus(_ response: URLResponse) throws {
        // file: URLs have no status
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure("GitHub answered with error \(http.statusCode).")
        }
    }

    /// Reopens once this process exits
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                             Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}
