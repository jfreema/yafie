import Foundation
import Network

/// Online: a network path, and traffic gets out
@MainActor
final class ConnectivityMonitor {
    private(set) var isOnline = true

    /// Probe only while it matters
    var isWatching = false {
        didSet {
            guard isWatching != oldValue else { return }
            failedProbes = 0
            if isWatching {
                probe(after: .zero)
            } else {
                probeTask?.cancel()
            }
        }
    }

    private let onChange: @MainActor () -> Void
    private let pathMonitor = NWPathMonitor()
    private var hasPath = true
    private var failedProbes = 0
    private var probeTask: Task<Void, Never>?
    private var offlineTask: Task<Void, Never>?

    /// Blips shorter than this don't count
    private static let grace: Duration = .seconds(30)
    private static let probeInterval: Duration = .seconds(60)
    private static let retryInterval: Duration = .seconds(20)
    private static let failuresBeforeOffline = 3
    /// What macOS checks for captive portals
    nonisolated private static let probeURL = URL(string: "https://captive.apple.com/hotspot-detect.html")!
    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        pathMonitor.pathUpdateHandler = { [weak self] path in
            // A VPN can stay up after the Wi-Fi under it goes, so it doesn't count alone
            let satisfied = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
                    || path.usesInterfaceType(.cellular))
            Task { @MainActor in self?.pathChanged(satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "yafie.connectivity"))
    }

    /// Network may have changed while asleep
    func recheck() {
        failedProbes = 0
        probe(after: .seconds(3))  // let Wi-Fi rejoin
    }

    private func pathChanged(_ satisfied: Bool) {
        guard satisfied != hasPath else { return }
        hasPath = satisfied
        offlineTask?.cancel()
        if satisfied {
            logger.notice("Network is back")
            if isWatching {
                probe(after: .zero)
            } else {
                set(online: true)
            }
        } else {
            logger.notice("Network went away")
            probeTask?.cancel()
            offlineTask = Task { [weak self] in
                try? await Task.sleep(for: Self.grace)
                guard !Task.isCancelled else { return }
                self?.set(online: false)
            }
        }
    }

    private func probe(after delay: Duration) {
        probeTask?.cancel()
        guard isWatching, hasPath else { return }
        probeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let reachable = await Self.canReachInternet()
            guard !Task.isCancelled else { return }
            self?.probed(reachable)
        }
    }

    private func probed(_ reachable: Bool) {
        if reachable {
            failedProbes = 0
            set(online: true)
        } else {
            failedProbes += 1
            logger.notice("Internet check failed (\(self.failedProbes, privacy: .public) in a row)")
            if failedProbes >= Self.failuresBeforeOffline { set(online: false) }
        }
        probe(after: failedProbes == 0 ? Self.probeInterval : Self.retryInterval)
    }

    private func set(online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        logger.notice("\(online ? "Online" : "Offline", privacy: .public)")
        onChange()
    }

    nonisolated private static func canReachInternet() async -> Bool {
        guard let (data, response) = try? await session.data(from: probeURL),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        // Captive portals answer with a login page
        return String(decoding: data, as: UTF8.self).contains("Success")
    }
}
