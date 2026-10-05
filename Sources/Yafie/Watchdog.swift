import Foundation

/// Restores sleep if app dies
@MainActor
final class Watchdog {
    static let argument = "--watchdog"

    var ownsSleepDisabled = false {
        didSet { send() }
    }
    private var process: Process?
    private var pipe: FileHandle?

    func start(ownsSleepDisabled: Bool) {
        self.ownsSleepDisabled = ownsSleepDisabled
        launch()
    }

    private func launch() {
        try? pipe?.close()
        pipe = nil
        guard let executable = Bundle.main.executableURL else { return }

        let channel = Pipe()
        let input = channel.fileHandleForWriting
        // EPIPE instead of SIGPIPE
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Keep out of child processes
        _ = fcntl(input.fileDescriptor, F_SETFD, FD_CLOEXEC)

        let process = Process()
        process.executableURL = executable
        process.arguments = [Self.argument]
        process.standardInput = channel.fileHandleForReading
        process.terminationHandler = { [weak self] _ in
            // Someone killed it, respawn
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))  // throttle
                self?.launch()
            }
        }
        do {
            try process.run()
        } catch {
            logger.error("Couldn't start the watchdog: \(error.localizedDescription, privacy: .public)")
            return
        }
        try? channel.fileHandleForReading.close()  // child's end
        self.process = process
        pipe = input
        send()
    }

    private func send() {
        // Respawn resends state
        try? pipe?.write(contentsOf: Data((ownsSleepDisabled ? "1\n" : "0\n").utf8))
    }

    /// Child side, blocks until EOF
    static func run() {
        // Must outlive the app
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
        }
        var owned = false
        while let line = readLine() {
            owned = line == "1"
        }
        guard owned else { return }

        logger.notice("Yafie quit without turning sleep back on")
        // Let in-flight writes land
        Thread.sleep(forTimeInterval: 1)
        guard SleepSetting.setSynchronously(disabled: false) else {
            logger.error("The watchdog couldn't turn sleep back on")
            return
        }
        logger.notice("The watchdog turned sleep back on")

        // Same lid check as app
        guard PowerManager.isLidClosed == true, PowerManager.lidClosingCausesSleep != false else { return }
        for _ in 1...10 {  // kernel lags after clearing
            if PowerManager.sleepNow() {
                logger.notice("The watchdog asked macOS to sleep")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        logger.error("macOS refused to sleep")
    }
}
