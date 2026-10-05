import Accelerate
import AppKit
import AVFoundation
import CoreAudio
import os

let tunerLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "yafie", category: "tuner")

/// The default input, analyzed for pitch, between start() and stop().
///
/// The microphone runs in a listener process: Yafie started with `--tuner-listen`. While devices change, recording
/// can spin inside Core Audio for good, and a process can be killed where a thread can't. It also keeps Core Audio off
/// the main thread, which runs lid sleep.
@MainActor
final class TunerAudio {
    enum Status: Equatable { case starting, listening, denied, noInput, failed(String) }

    /// What runs as the listener: Yafie itself, unless a test stands in
    struct Listener {
        var executable: URL
        var arguments: [String]

        static var yafie: Listener? {
            Bundle.main.executableURL.map { Listener(executable: $0, arguments: [TunerListener.argument]) }
        }
    }

    static var isMicrophoneAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    private let listener: Listener?
    /// A listener that says nothing for this long is stuck
    private let silenceLimit: TimeInterval
    /// A device that's mid-change needs a moment before the next try
    private let settleTime: TimeInterval
    private let onStatus: @MainActor (Status) -> Void
    private let onHeard: @MainActor (Heard) -> Void
    private var process: Process?
    /// The listener's stdin, which closes when the app goes
    private var listenerInput: FileHandle?
    private var isWanted = false
    private var startTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    /// Tells an ended listener's last lines apart
    private var session = 0
    private var lastNews: TimeInterval = 0
    /// Listeners in a row that ended before any sound got through
    private var failures = 0

    init(listener: Listener? = .yafie, silenceLimit: TimeInterval = 5, settleTime: TimeInterval = 2,
         onStatus: @escaping @MainActor (Status) -> Void, onHeard: @escaping @MainActor (Heard) -> Void) {
        self.listener = listener
        self.silenceLimit = silenceLimit
        self.settleTime = settleTime
        self.onStatus = onStatus
        self.onHeard = onHeard
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterWake() }
        }
    }

    func start() {
        isWanted = true
        guard process == nil, startTask == nil, settleTask == nil else { return }
        onStatus(.starting)
        startTask = Task {
            let allowed = await Self.askForMicrophone()
            startTask = nil
            guard isWanted else { return }  // closed while macOS asked
            if allowed {
                listen()
            } else {
                tunerLogger.notice("Microphone access is off")
                onStatus(.denied)
            }
        }
    }

    /// Once the microphone's allowed. Tests start here.
    func listen() {
        isWanted = true
        failures = 0
        launch()
    }

    func stop() {
        isWanted = false
        if process != nil { tunerLogger.notice("Stopped listening") }
        endListener()
    }

    nonisolated private static func askForMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func launch() {
        guard let listener else {
            onStatus(.failed("Couldn't find Yafie's listener."))
            return
        }
        session += 1
        let current = session
        let process = Process()
        process.executableURL = listener.executable
        process.arguments = listener.arguments
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        // Keep our end out of other children, so the listener's stdin closes with the app
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        do {
            try process.run()
        } catch {
            tunerLogger.error("Couldn't start listening: \(error.localizedDescription, privacy: .public)")
            onStatus(.failed(error.localizedDescription))
            return
        }
        // The listener's ends, so reading stops when it does
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        self.process = process
        listenerInput = input.fileHandleForWriting
        lastNews = ProcessInfo.processInfo.systemUptime
        Self.readLines(from: output.fileHandleForReading) { [weak self] line in
            Task { @MainActor in
                if let line { self?.received(line, session: current) } else { self?.ended(session: current) }
            }
        }
        watchTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(0.5, silenceLimit / 4)))
                guard !Task.isCancelled, session == current else { return }
                if ProcessInfo.processInfo.systemUptime - lastNews > silenceLimit {
                    tunerLogger.error("The audio input isn't responding")
                    relaunch(because: "The audio input isn't responding.")
                    return
                }
            }
        }
    }

    /// On a thread of its own, since reading a pipe blocks. Ends with nil when the listener does.
    nonisolated private static func readLines(from reader: FileHandle, _ deliver: @escaping @Sendable (String?) -> Void) {
        Thread.detachNewThread {
            var pending = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(reader.fileDescriptor, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                pending += chunk[..<count]
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    deliver(String(decoding: pending[..<newline], as: UTF8.self))
                    pending.removeSubrange(...newline)
                }
            }
            deliver(nil)
        }
    }

    private func received(_ line: String, session: Int) {
        guard session == self.session, let message = ListenerMessage(line: line) else { return }
        lastNews = ProcessInfo.processInfo.systemUptime
        switch message {
        case let .listening(device, sampleRate, channels):
            tunerLogger.notice("Listening to \(device, privacy: .public) at \(Int(sampleRate)) Hz, \(channels) channels")
            onStatus(.listening)
        case .heard(let heard):
            failures = 0  // sound is getting through
            if let pitch = heard.pitch {
                tunerLogger.debug("Heard \(pitch.frequency, format: .fixed(precision: 2)) Hz, clarity \(pitch.clarity, format: .fixed(precision: 2))")
            }
            onHeard(heard)
        case .changed:
            tunerLogger.notice("Audio input changed, restarting")
            relaunch(because: "The audio input keeps changing.")
        case .noInput:
            tunerLogger.error("No audio input")
            endListener()
            onStatus(.noInput)
        case .failed(let reason):
            tunerLogger.error("Couldn't start listening: \(reason, privacy: .public)")
            endListener()
            onStatus(.failed(reason))
        }
    }

    /// Its output closed though nothing here ended it
    private func ended(session: Int) {
        guard session == self.session else { return }
        tunerLogger.error("The listener quit")
        relaunch(because: "The audio input stopped.")
    }

    /// Again after a pause, since a device that's mid-change usually settles. Gives up when listeners keep ending
    /// before any sound gets through.
    private func relaunch(because reason: String) {
        endListener()
        failures += 1
        guard failures < 2 else {
            onStatus(.failed("\(reason) Try again, or choose another input in System Settings → Sound."))
            return
        }
        launchAfterSettling()
    }

    /// The audio hardware went away while the Mac slept
    private func restartAfterWake() {
        guard process != nil else { return }
        endListener()
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
    private func endListener() {
        session += 1
        settleTask?.cancel()
        settleTask = nil
        watchTask?.cancel()
        watchTask = nil
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? listenerInput?.close()
        process = nil
        listenerInput = nil
    }
}

/// The listener process's side: reports what it hears on stdout until the app closes its stdin or kills it.
///
/// It records with AVCaptureSession, which only records: no output device is ever opened, so nothing the tuner hears
/// is played back. And it only opens built-in and wired inputs (see TunerInput).
enum TunerListener {
    static let argument = "--tuner-listen"

    static func run() -> Never {
        signal(SIGPIPE, SIG_DFL)  // the app's gone, so go too
        // Leaves with the app even if Core Audio has the main thread stuck
        Thread.detachNewThread {
            while readLine() != nil {}
            _exit(0)
        }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                       position: .unspecified).devices
        let preferred = AVCaptureDevice.default(for: .audio)?.uniqueID
        let inputs = devices.map { device in
            TunerInput(id: device.uniqueID, name: device.localizedName,
                       transport: UInt32(bitPattern: device.transportType), isDefault: device.uniqueID == preferred)
        }
        guard let input = TunerInput.choose(from: inputs),
              let device = devices.first(where: { $0.uniqueID == input.id }) else { finish(.noInput) }

        let session = AVCaptureSession()
        do {
            let deviceInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(deviceInput) else { finish(.failed("Couldn't use \(input.name).")) }
            session.addInput(deviceInput)
        } catch {
            finish(.failed(error.localizedDescription))
        }
        let output = AVCaptureAudioDataOutput()
        // Float samples, a buffer per channel, at the device's own rate
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true]
        let recorder = Recorder(device: input.name)
        output.setSampleBufferDelegate(recorder, queue: DispatchQueue(label: "yafie.tuner.listen"))
        guard session.canAddOutput(output) else { finish(.failed("Couldn't record from \(input.name).")) }
        session.addOutput(output)
        watchForChanges()
        session.startRunning()
        // Nothing else holds them, and Swift may free a local after its last use
        withExtendedLifetime((session, recorder)) { dispatchMain() }
    }

    /// The input it chose may not be the right one any more: the default input changed, a device came or went, or
    /// the recording stopped. The app starts a new listener once things settle.
    private static func watchForChanges() {
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification,
                     AVCaptureSession.runtimeErrorNotification] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in send(.changed) }
        }
        var defaultInput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInput, nil) { _, _ in
            send(.changed)
        }
    }

    fileprivate static func send(_ message: ListenerMessage) {
        try? FileHandle.standardOutput.write(contentsOf: Data((message.line + "\n").utf8))
    }

    private static func finish(_ message: ListenerMessage) -> Never {
        send(message)
        _exit(0)
    }
}

/// Turns each recorded buffer into a reading. Only the capture queue touches it.
private final class Recorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let device: String
    private var analyzer: PitchAnalyzer?

    init(device: String) {
        self.device = device
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr else { return }
        if analyzer == nil {
            // The first buffer says what the device really delivers
            TunerListener.send(.listening(device: device, sampleRate: format.sampleRate,
                                          channels: Int(format.channelCount)))
            analyzer = PitchAnalyzer(sampleRate: format.sampleRate)
        }
        guard let analyzer else { return }
        TunerListener.send(.heard(analyzer.process(buffer)))
    }
}

/// An audio input the tuner might open
struct TunerInput: Equatable, Sendable {
    /// Built-in and wired only. Opening a Bluetooth headset's microphone switches it to call mode, which can make
    /// everything it plays suddenly much louder. Virtual and aggregate devices can carry other apps' sound.
    static let safeTransports: Set<UInt32> = [
        kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire,
        kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeAVB,
    ]

    let id: String
    let name: String
    /// Core Audio's transport type: built-in, USB, Bluetooth and so on
    let transport: UInt32
    /// Chosen in System Settings → Sound → Input
    let isDefault: Bool

    var isSafe: Bool { Self.safeTransports.contains(transport) }

    /// The input chosen in System Settings if it's safe, or else the Mac's own microphone, or else any safe input
    static func choose(from inputs: [TunerInput]) -> TunerInput? {
        let safe = inputs.filter(\.isSafe)
        return safe.first(where: \.isDefault) ?? safe.first { $0.transport == kAudioDeviceTransportTypeBuiltIn }
            ?? safe.first
    }
}

/// One buffer's worth of sound
struct Heard: Equatable, Sendable {
    /// Nil unless it's clearly a note
    var pitch: Pitch?
    /// RMS in dBFS, down to −120 for silence
    var level: Float

    static let silence: Float = -120
}

/// What the listener reports, a line each
enum ListenerMessage: Equatable, Sendable {
    case listening(device: String, sampleRate: Double, channels: Int)
    case heard(Heard)
    case changed
    case noInput
    case failed(String)

    var line: String {
        switch self {
        case let .listening(device, sampleRate, channels): "listening \(sampleRate) \(channels) \(Self.oneLine(device))"
        case .heard(let heard):
            if let pitch = heard.pitch { "heard \(heard.level) \(pitch.frequency) \(pitch.clarity)" } else { "heard \(heard.level) -" }
        case .changed: "changed"
        case .noInput: "noinput"
        case .failed(let reason): "failed \(Self.oneLine(reason))"
        }
    }

    init?(line: String) {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        switch parts[0] {
        case "listening":
            guard parts.count == 4, let sampleRate = Double(parts[1]), let channels = Int(parts[2]) else { return nil }
            self = .listening(device: parts[3], sampleRate: sampleRate, channels: channels)
        case "heard":
            guard parts.count > 2, let level = Float(parts[1]) else { return nil }
            if parts.count == 3, parts[2] == "-" {
                self = .heard(Heard(level: level))
                return
            }
            guard parts.count == 4, let frequency = Double(parts[2]), let clarity = Float(parts[3]) else { return nil }
            self = .heard(Heard(pitch: Pitch(frequency: frequency, clarity: clarity), level: level))
        case "changed" where parts.count == 1:
            self = .changed
        case "noinput" where parts.count == 1:
            self = .noInput
        case "failed" where parts.count > 1:
            self = .failed(parts.dropFirst().joined(separator: " "))
        default:
            return nil
        }
    }

    private static func oneLine(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: " ") }
}

/// Owned by the tap, which AVAudioEngine calls one buffer at a time on its own thread, so nothing else touches it
final class PitchAnalyzer: @unchecked Sendable {
    private let detector: PitchDetector
    private var window: [Float]
    private var filled = 0
    private var channel = 0

    init(sampleRate: Double) {
        detector = PitchDetector(sampleRate: sampleRate)
        window = [Float](repeating: 0, count: detector.windowSize)
    }

    func process(_ buffer: AVAudioPCMBuffer) -> Heard {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return Heard(level: Heard.silence) }
        let frames = Int(buffer.frameLength)
        followLoudest(channels, count: Int(buffer.format.channelCount), frames: frames)
        var power: Float = 0
        vDSP_measqv(channels[channel], 1, &power, vDSP_Length(frames))
        let level = power > 0 ? max(Heard.silence, 10 * log10(power)) : Heard.silence
        let fresh = UnsafeBufferPointer(start: channels[channel], count: frames)
        if frames >= window.count {
            window = Array(fresh.suffix(window.count))
        } else {
            window.removeFirst(frames)
            window.append(contentsOf: fresh)
        }
        filled = min(filled + frames, window.count)
        guard filled == window.count else { return Heard(level: level) }
        return Heard(pitch: detector.detect(window), level: level)
    }

    /// So a guitar on input 2 of an interface works. Inputs 1 and 2 only: an interface's later channels can be
    /// loopback, carrying the Mac's own sound. Switches only to a clearly louder channel, so the window doesn't flip
    /// between two that carry the same sound.
    private func followLoudest(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, count all: Int, frames: Int) {
        let count = min(all, 2)
        guard count > 1 else {
            channel = 0
            return
        }
        var powers = [Float](repeating: 0, count: count)
        for index in 0..<count { vDSP_measqv(channels[index], 1, &powers[index], vDSP_Length(frames)) }
        if channel >= count { channel = 0 }
        if let loudest = powers.indices.max(by: { powers[$0] < powers[$1] }), powers[loudest] > 4 * powers[channel] {
            channel = loudest
        }
    }
}
