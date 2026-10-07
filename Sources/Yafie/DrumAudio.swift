import AppKit
import os

let drumLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "yafie", category: "drums")

/// The drum machine's player process, from the app's side. It runs while the drum machine is open, and starts over
/// when the sound output changes, the Mac wakes, or it stops answering.
@MainActor
final class DrumAudio {
    enum Status: Equatable { case starting, ready, failed(String) }

    /// What runs as the player: Yafie itself, unless a test stands in
    struct Player {
        var executable: URL
        var arguments: [String]

        static var yafie: Player? {
            Bundle.main.executableURL.map { Player(executable: $0, arguments: [DrumPlayer.argument]) }
        }
    }

    private let player: Player?
    /// A player that says nothing for this long is stuck. It says it's alive twice a second.
    private let silenceLimit: TimeInterval
    /// A device that's mid-change needs a moment before the next try
    private let settleTime: TimeInterval
    private let onStatus: @MainActor (Status) -> Void
    private let onMessage: @MainActor (DrumMessage) -> Void
    private var process: Process?
    /// The player's stdin, for commands. It closes when the app goes, and the player goes with it.
    private var commands: FileHandle?
    private var isWanted = false
    private var settleTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    /// Tells an ended player's last lines apart
    private var session = 0
    private var lastNews: TimeInterval = 0
    /// Players in a row that ended before they were ready
    private var failures = 0

    init(player: Player? = .yafie, silenceLimit: TimeInterval = 5, settleTime: TimeInterval = 1,
         onStatus: @escaping @MainActor (Status) -> Void, onMessage: @escaping @MainActor (DrumMessage) -> Void) {
        self.player = player
        self.silenceLimit = silenceLimit
        self.settleTime = settleTime
        self.onStatus = onStatus
        self.onMessage = onMessage
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterWake() }
        }
    }

    func start() {
        isWanted = true
        failures = 0
        guard process == nil, settleTask == nil else { return }
        launch()
    }

    func stop() {
        isWanted = false
        if process != nil { drumLogger.notice("Stopped the drum player") }
        endPlayer()
    }

    /// Never waits: a command a stuck player can't take is dropped, and it's told everything again when it starts over
    func send(_ command: DrumCommand) {
        guard let commands else { return }
        let bytes = Array((command.line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(commands.fileDescriptor, $0.baseAddress, $0.count) }
    }

    private func launch() {
        guard let player else {
            onStatus(.failed("Couldn't find Yafie's drum player."))
            return
        }
        session += 1
        let current = session
        onStatus(.starting)
        let process = Process()
        process.executableURL = player.executable
        process.arguments = player.arguments
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        let ours = input.fileHandleForWriting.fileDescriptor
        // Kept out of other children, so the player's stdin closes with the app. Writing never waits on the player,
        // and a player that's gone can't take Yafie with it.
        _ = fcntl(ours, F_SETFD, FD_CLOEXEC)
        _ = fcntl(ours, F_SETFL, O_NONBLOCK)
        _ = fcntl(ours, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            drumLogger.error("Couldn't start the drum player: \(error.localizedDescription, privacy: .public)")
            onStatus(.failed(error.localizedDescription))
            return
        }
        // The player's ends, so reading stops when it does
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        self.process = process
        commands = input.fileHandleForWriting
        lastNews = ProcessInfo.processInfo.systemUptime
        Shell.readLines(from: output.fileHandleForReading) { [weak self] line in
            Task { @MainActor in
                if let line { self?.received(line, session: current) } else { self?.ended(session: current) }
            }
        }
        watchTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(0.5, silenceLimit / 4)))
                guard !Task.isCancelled, session == current else { return }
                if ProcessInfo.processInfo.systemUptime - lastNews > silenceLimit {
                    drumLogger.error("The drum player isn't responding")
                    relaunch(because: "The sound output isn't responding.")
                    return
                }
            }
        }
    }

    private func received(_ line: String, session: Int) {
        guard session == self.session, let message = DrumMessage(line: line) else { return }
        lastNews = ProcessInfo.processInfo.systemUptime
        switch message {
        case .ready(let sampleRate):
            failures = 0
            drumLogger.notice("Drum player ready at \(Int(sampleRate)) Hz")
            onStatus(.ready)
        case .changed:
            drumLogger.notice("Sound output changed, restarting the drum player")
            relaunch(because: "The sound output keeps changing.")
        case .failed(let reason):
            drumLogger.error("The drum player couldn't start: \(reason, privacy: .public)")
            endPlayer()
            onStatus(.failed(reason))
        case .alive:
            break
        case .beat, .played, .recorded:
            onMessage(message)
        }
    }

    /// Its output closed though nothing here ended it
    private func ended(session: Int) {
        guard session == self.session else { return }
        drumLogger.error("The drum player quit")
        relaunch(because: "The drum player stopped.")
    }

    /// Again after a pause, since a device that's mid-change usually settles. Gives up when players keep ending
    /// before they're ready.
    private func relaunch(because reason: String) {
        endPlayer()
        failures += 1
        guard failures < 3 else {
            onStatus(.failed("\(reason) Try again, or choose another output in System Settings → Sound."))
            return
        }
        launchAfterSettling()
    }

    /// The audio hardware may have gone away while the Mac slept
    private func restartAfterWake() {
        guard process != nil else { return }
        endPlayer()
        launchAfterSettling()
    }

    private func launchAfterSettling() {
        onStatus(.starting)
        settleTask = Task {
            try? await Task.sleep(for: .seconds(settleTime))
            guard !Task.isCancelled, isWanted else { return }
            settleTask = nil
            launch()
        }
    }

    /// Kills it outright: it holds nothing worth saving, and a stuck one wouldn't answer anything gentler
    private func endPlayer() {
        session += 1
        settleTask?.cancel()
        settleTask = nil
        watchTask?.cancel()
        watchTask = nil
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? commands?.close()
        process = nil
        commands = nil
    }
}
