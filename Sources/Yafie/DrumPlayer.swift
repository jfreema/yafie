import AVFoundation
import CoreAudio
import os

/// The drum machine's sound, made in a player process: Yafie started with `--drum-play`. Like the tuner's listener, a
/// process can be killed if Core Audio gets stuck when the output device changes, where a thread can't, and the main
/// thread runs lid sleep. It only plays: it never opens an input.
enum DrumPlayer {
    static let argument = "--drum-play"

    static func run() -> Never {
        signal(SIGPIPE, SIG_DFL)  // the app's gone, so go too
        let engine = AVAudioEngine()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            finish(.failed("There's no sound output."))
        }
        let core = DrumCore(sampleRate: rate)
        let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                core.render(Int(frames), into: samples)
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            finish(.failed(error.localizedDescription))
        }
        // From making a sound to hearing it, so recorded hits land where they were heard
        core.setLatency(engine.outputNode.presentationLatency * rate + 256)
        watchForChanges(engine)
        send(.ready(sampleRate: rate))

        // Commands, until the app closes its end
        Thread.detachNewThread {
            while let line = readLine() {
                if let command = DrumCommand(line: line) { core.perform(command) }
            }
            _exit(0)
        }
        // Reports, and word that it's alive when there's nothing to report
        Thread.detachNewThread {
            var quiet = 0
            while true {
                let reports = core.takeReports()
                for report in reports { send(DrumMessage(report)) }
                quiet = reports.isEmpty ? quiet + 1 : 0
                if quiet == 50 {
                    send(.alive)
                    quiet = 0
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        // Nothing else holds them, and Swift may free a local after its last use
        withExtendedLifetime((engine, source, core)) { dispatchMain() }
    }

    /// A new or changed output device means starting over. The app starts a new player once things settle.
    private static func watchForChanges(_ engine: AVAudioEngine) {
        _ = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                   queue: nil) { _ in finish(.changed) }
        var defaultOutput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutput, nil) { _, _ in
            finish(.changed)
        }
    }

    private static func send(_ message: DrumMessage) {
        try? FileHandle.standardOutput.write(contentsOf: Data((message.line + "\n").utf8))
    }

    private static func finish(_ message: DrumMessage) -> Never {
        send(message)
        _exit(0)
    }
}

/// What the player's threads share: commands come in on one, the audio thread renders, and another sends reports.
/// A lock guards the sequencer, held only briefly.
final class DrumCore: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var sequencer: DrumSequencer
    /// Hits played live, for the next buffer
    private var pending: [DrumSequencer.Event] = []
    private var reports: [DrumSequencer.Report] = []
    private var latency: Double = 0
    // The audio thread's alone
    private var mixer: DrumMixer
    private var events: [DrumSequencer.Event] = []

    init(sampleRate: Double) {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        sequencer = DrumSequencer(sampleRate: sampleRate)
        mixer = DrumMixer(sounds: DrumKit.sounds(sampleRate: sampleRate))
        pending.reserveCapacity(64)
        reports.reserveCapacity(256)
        events.reserveCapacity(256)
    }

    func setLatency(_ frames: Double) {
        locked { latency = frames }
    }

    func perform(_ command: DrumCommand) {
        locked {
            switch command {
            case .hit(let pad): sequencer.hit(pad, latency: latency, events: &pending, reports: &reports)
            case .tempo(let tempo): sequencer.tempo = tempo
            case .metronome(let on): sequencer.isMetronomeOn = on
            case .bars(let bars): sequencer.setBars(bars)
            case .play: sequencer.play()
            case .stop: sequencer.stop()
            case .record: sequencer.record()
            case .clear: sequencer.clear()
            case .load(let notes): sequencer.load(notes)
            }
        }
    }

    /// On the audio thread
    func render(_ frames: Int, into output: UnsafeMutablePointer<Float>) {
        locked {
            events.append(contentsOf: pending)
            pending.removeAll(keepingCapacity: true)
            sequencer.advance(frames, events: &events, reports: &reports)
        }
        mixer.mix(frames, starting: events, into: output)
        events.removeAll(keepingCapacity: true)
    }

    func takeReports() -> [DrumSequencer.Report] {
        locked {
            let taken = reports
            reports.removeAll(keepingCapacity: true)
            return taken
        }
    }

    private func locked<Result>(_ body: () -> Result) -> Result {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }
}

/// What the app tells the player, a line each
enum DrumCommand: Equatable, Sendable {
    case hit(DrumPad)
    case tempo(Double)
    case metronome(Bool)
    case bars(Int)
    case play, stop, record, clear
    /// The loop, after the player started over
    case load(Set<DrumNote>)

    var line: String {
        switch self {
        case .hit(let pad): "hit \(pad.rawValue)"
        case .tempo(let tempo): "tempo \(tempo)"
        case .metronome(let on): "metronome \(on ? "on" : "off")"
        case .bars(let bars): "bars \(bars)"
        case .play: "play"
        case .stop: "stop"
        case .record: "record"
        case .clear: "clear"
        case .load(let notes):
            (["load"] + notes.sorted { ($0.step, $0.pad.rawValue) < ($1.step, $1.pad.rawValue) }
                .map { "\($0.pad.rawValue):\($0.step)" }).joined(separator: " ")
        }
    }

    init?(line: String) {
        let parts = line.split(separator: " ").map(String.init)
        guard let word = parts.first else { return nil }
        switch (word, parts.count) {
        case ("hit", 2):
            guard let pad = DrumPad(rawValue: parts[1]) else { return nil }
            self = .hit(pad)
        case ("tempo", 2):
            guard let tempo = Double(parts[1]) else { return nil }
            self = .tempo(tempo)
        case ("metronome", 2) where parts[1] == "on" || parts[1] == "off":
            self = .metronome(parts[1] == "on")
        case ("bars", 2):
            guard let bars = Int(parts[1]), bars == 1 || bars == 4 else { return nil }
            self = .bars(bars)
        case ("play", 1): self = .play
        case ("stop", 1): self = .stop
        case ("record", 1): self = .record
        case ("clear", 1): self = .clear
        case ("load", _):
            var notes = Set<DrumNote>()
            for token in parts.dropFirst() {
                let pair = token.split(separator: ":").map(String.init)
                guard pair.count == 2, let pad = DrumPad(rawValue: pair[0]), let step = Int(pair[1]) else { return nil }
                notes.insert(DrumNote(pad: pad, step: step))
            }
            self = .load(notes)
        default:
            return nil
        }
    }
}

/// What the player tells the app, a line each
enum DrumMessage: Equatable, Sendable {
    case ready(sampleRate: Double)
    case beat(bar: Int, beat: Int, phase: DrumSequencer.Phase)
    case played(DrumPad)
    case recorded(DrumNote)
    /// Nothing else to say for a while
    case alive
    case changed
    case failed(String)

    init(_ report: DrumSequencer.Report) {
        switch report {
        case let .beat(bar, beat, phase): self = .beat(bar: bar, beat: beat, phase: phase)
        case .played(let pad): self = .played(pad)
        case .recorded(let note): self = .recorded(note)
        }
    }

    var line: String {
        switch self {
        case .ready(let sampleRate): "ready \(sampleRate)"
        case let .beat(bar, beat, phase): "beat \(bar) \(beat) \(phase.rawValue)"
        case .played(let pad): "played \(pad.rawValue)"
        case .recorded(let note): "recorded \(note.pad.rawValue) \(note.step)"
        case .alive: "alive"
        case .changed: "changed"
        case .failed(let reason): "failed \(reason.replacingOccurrences(of: "\n", with: " "))"
        }
    }

    init?(line: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        switch (parts[0], parts.count) {
        case ("ready", 2):
            guard let sampleRate = Double(parts[1]) else { return nil }
            self = .ready(sampleRate: sampleRate)
        case ("beat", 4):
            guard let bar = Int(parts[1]), let beat = Int(parts[2]), let phase = DrumSequencer.Phase(rawValue: parts[3])
            else { return nil }
            self = .beat(bar: bar, beat: beat, phase: phase)
        case ("played", 2):
            guard let pad = DrumPad(rawValue: parts[1]) else { return nil }
            self = .played(pad)
        case ("recorded", 3):
            guard let pad = DrumPad(rawValue: parts[1]), let step = Int(parts[2]) else { return nil }
            self = .recorded(DrumNote(pad: pad, step: step))
        case ("alive", 1): self = .alive
        case ("changed", 1): self = .changed
        case ("failed", 2...): self = .failed(parts.dropFirst().joined(separator: " "))
        default: return nil
        }
    }
}
