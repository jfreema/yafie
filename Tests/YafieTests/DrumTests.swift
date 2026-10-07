import Foundation
import Testing
@testable import Yafie

struct DrumPadTests {
    @Test func theTrackpadsCornersAreTheDrums() {
        #expect(DrumPad(at: CGPoint(x: 0.1, y: 0.9)) == .snare)
        #expect(DrumPad(at: CGPoint(x: 0.9, y: 0.9)) == .kick)
        #expect(DrumPad(at: CGPoint(x: 0.1, y: 0.1)) == .hiHat)
        #expect(DrumPad(at: CGPoint(x: 0.9, y: 0.1)) == .hiHat)
        #expect(DrumPad(at: CGPoint(x: 0.5, y: 0.5)) == .kick)
    }
}

/// At 120 beats a minute and 48 kHz, a sixteenth is 6,000 frames, a beat 24,000 and a bar 96,000
struct DrumSequencerTests {
    private static let step = 6000
    private static let beat = 4 * step
    private static let bar = 4 * beat

    /// Runs it in 512-frame buffers, as the audio thread does, giving each sound's frame from where this started
    private func run(_ sequencer: inout DrumSequencer, for frames: Int)
        -> (sounds: [(sound: DrumSound, frame: Int)], reports: [DrumSequencer.Report]) {
        var sounds: [(DrumSound, Int)] = []
        var reports: [DrumSequencer.Report] = []
        var done = 0
        while done < frames {
            let count = min(512, frames - done)
            var events: [DrumSequencer.Event] = []
            sequencer.advance(count, events: &events, reports: &reports)
            sounds += events.map { ($0.sound, done + $0.offset) }
            done += count
        }
        return (sounds, reports)
    }

    private func sequencer() -> DrumSequencer {
        var sequencer = DrumSequencer(sampleRate: 48000)
        sequencer.tempo = 120
        return sequencer
    }

    @Test func clicksEveryBeatWithEachBarsFirstHigher() {
        var sequencer = sequencer()
        sequencer.play()
        let (sounds, reports) = run(&sequencer, for: 2 * Self.bar)
        #expect(sounds.map(\.frame) == (0..<8).map { $0 * Self.beat })
        #expect(sounds.map(\.sound) == [.accent, .click, .click, .click, .accent, .click, .click, .click])
        #expect(reports.first == .beat(bar: 1, beat: 1, phase: .playing))
        #expect(reports.last == .beat(bar: 1, beat: 4, phase: .playing))
    }

    @Test func theMetronomeCanBeQuiet() {
        var sequencer = sequencer()
        sequencer.isMetronomeOn = false
        sequencer.play()
        #expect(run(&sequencer, for: Self.bar).sounds.isEmpty)
    }

    @Test func recordingFromAStopCountsInForABar() {
        var sequencer = sequencer()
        sequencer.isMetronomeOn = false
        sequencer.record()
        let (sounds, reports) = run(&sequencer, for: Self.bar + Self.beat)
        // The count-in clicks even with the metronome off
        #expect(sounds.map(\.sound) == [.accent, .click, .click, .click])
        #expect(Array(reports.prefix(4)) == (1...4).map { .beat(bar: 0, beat: $0, phase: .countIn) })
        #expect(reports.last == .beat(bar: 1, beat: 1, phase: .recording))
        #expect(sequencer.isRecording)
    }

    @Test func hitsJoinTheLoopAtTheNearestSixteenth() {
        var sequencer = sequencer()
        sequencer.isMetronomeOn = false
        sequencer.play()
        sequencer.record()
        _ = run(&sequencer, for: 4 * Self.step + 2000)  // a third of the way into the fifth sixteenth
        var events: [DrumSequencer.Event] = []
        var reports: [DrumSequencer.Report] = []
        sequencer.hit(.snare, latency: 0, events: &events, reports: &reports)
        #expect(events == [DrumSequencer.Event(sound: .snare, offset: 0)])
        #expect(reports == [.recorded(DrumNote(pad: .snare, step: 4))])
        // Next time round, the loop plays it
        let rest = run(&sequencer, for: Self.bar)
        #expect(rest.sounds.map(\.sound) == [.snare])
        #expect(rest.sounds.first?.frame == Self.bar - 2000)
    }

    @Test func aHitRoundedUpIsntPlayedTwice() {
        var sequencer = sequencer()
        sequencer.isMetronomeOn = false
        sequencer.play()
        sequencer.record()
        _ = run(&sequencer, for: 3 * Self.step + 4000)  // late in the fourth sixteenth
        var events: [DrumSequencer.Event] = []
        var reports: [DrumSequencer.Report] = []
        sequencer.hit(.kick, latency: 0, events: &events, reports: &reports)
        #expect(reports == [.recorded(DrumNote(pad: .kick, step: 4))])
        // Not again a moment later, only the pass after
        let rest = run(&sequencer, for: Self.bar + Self.step)
        #expect(rest.sounds.map(\.frame) == [Self.bar + 4 * Self.step - (3 * Self.step + 4000)])
    }

    @Test func whatWasHeardCountsNotWhatWasMade() {
        var sequencer = sequencer()
        sequencer.play()
        sequencer.record()
        _ = run(&sequencer, for: 4 * Self.step + 3600)
        var events: [DrumSequencer.Event] = []
        var reports: [DrumSequencer.Report] = []
        // Half a sixteenth on its way out to the speakers
        sequencer.hit(.hiHat, latency: 3000, events: &events, reports: &reports)
        #expect(reports == [.recorded(DrumNote(pad: .hiHat, step: 4))])
    }

    @Test func recordingStopsAfterOnePass() {
        var sequencer = sequencer()
        sequencer.play()
        sequencer.record()
        _ = run(&sequencer, for: Self.bar + 2 * Self.step)
        #expect(!sequencer.isRecording)
        var events: [DrumSequencer.Event] = []
        var reports: [DrumSequencer.Report] = []
        sequencer.hit(.kick, latency: 0, events: &events, reports: &reports)
        #expect(reports.isEmpty && sequencer.pattern.isEmpty)
        #expect(events.count == 1)  // still played
    }

    @Test func fourBarsRepeatTheBarAndOneKeepsTheFirst() {
        let bar: Set = [DrumNote(pad: .kick, step: 0), DrumNote(pad: .snare, step: 8)]
        let four = DrumSequencer.resized(bar, from: 1, to: 4)
        #expect(four.count == 8)
        #expect(four.contains(DrumNote(pad: .snare, step: 56)))
        #expect(DrumSequencer.resized(four.union([DrumNote(pad: .hiHat, step: 20)]), from: 4, to: 1) == bar)
    }

    @Test func aNewTempoKeepsThePlace() {
        var sequencer = sequencer()
        sequencer.play()
        _ = run(&sequencer, for: Self.beat)
        sequencer.tempo = 60
        #expect(sequencer.position == 4)
        #expect(sequencer.framesPerStep == 12000)
        sequencer.tempo = 500
        #expect(sequencer.tempo == 240)
    }

    @Test func loadingKeepsOnlyWhatFitsTheLoop() {
        var sequencer = sequencer()
        sequencer.load([DrumNote(pad: .kick, step: 4), DrumNote(pad: .kick, step: 20)])
        #expect(sequencer.pattern == [DrumNote(pad: .kick, step: 4)])
    }
}

struct DrumMixerTests {
    @Test func aSoundStartsAtItsOffsetAndCarriesOn() {
        var mixer = DrumMixer(sounds: [[Float](repeating: 0.5, count: 10)], gain: 1)
        var output = [Float](repeating: 9, count: 8)
        let start = [DrumSequencer.Event(sound: .kick, offset: 3)]
        output.withUnsafeMutableBufferPointer { mixer.mix(8, starting: start, into: $0.baseAddress!) }
        #expect(output == [0, 0, 0, 0.5, 0.5, 0.5, 0.5, 0.5])
        output.withUnsafeMutableBufferPointer { mixer.mix(8, starting: [], into: $0.baseAddress!) }
        #expect(output == [0.5, 0.5, 0.5, 0.5, 0.5, 0, 0, 0])
        #expect(mixer.isSilent)
    }

    @Test func soundsTogetherAddUpButNeverClip() {
        var mixer = DrumMixer(sounds: [[Float](repeating: 0.7, count: 4)], gain: 1)
        var output = [Float](repeating: 0, count: 4)
        let starts = [DrumSequencer.Event(sound: .kick, offset: 0), .init(sound: .kick, offset: 2)]
        output.withUnsafeMutableBufferPointer { mixer.mix(4, starting: starts, into: $0.baseAddress!) }
        #expect(output == [0.7, 0.7, 1, 1])
    }
}

struct DrumKitTests {
    private let sounds = DrumKit.sounds(sampleRate: 48000)

    @Test func eachSoundIsShortAndEndsQuietly() {
        #expect(sounds.count == DrumSound.allCases.count)
        for sound in sounds {
            let peak = sound.map(abs).max() ?? 0
            #expect(peak > 0.2 && peak <= 1)
            #expect(sound.count < 48000)
            #expect(abs(sound.last ?? 1) < 0.01)
        }
    }

    @Test func theKickIsLowAndTheHiHatHigh() {
        func crossings(_ sound: DrumSound) -> Double {
            let samples = sounds[sound.rawValue]
            let count = zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
            return Double(count) / (Double(samples.count) / 48000)
        }
        #expect(crossings(.kick) < 300)
        #expect(crossings(.hiHat) > 5000)
    }
}

struct DrumLineTests {
    @Test(arguments: [DrumCommand.hit(.hiHat), .tempo(92), .metronome(false), .bars(4), .play, .stop, .record, .clear,
                      .load([DrumNote(pad: .kick, step: 0), DrumNote(pad: .snare, step: 12)]), .load([])])
    func commandsRoundTrip(command: DrumCommand) {
        #expect(DrumCommand(line: command.line) == command)
    }

    @Test(arguments: [DrumMessage.ready(sampleRate: 48000), .beat(bar: 0, beat: 3, phase: .countIn),
                      .played(.snare), .recorded(DrumNote(pad: .hiHat, step: 63)), .alive, .changed,
                      .failed("There's no sound output.")])
    func messagesRoundTrip(message: DrumMessage) {
        #expect(DrumMessage(line: message.line) == message)
    }

    @Test(arguments: ["", "hit", "hit cowbell", "bars 2", "tempo fast", "metronome maybe", "load kick", "play now"])
    func ignoresGarbageCommands(line: String) {
        #expect(DrumCommand(line: line) == nil)
    }

    @Test(arguments: ["", "beat 1 2", "beat 1 2 dance", "recorded kick", "played", "ready"])
    func ignoresGarbageMessages(line: String) {
        #expect(DrumMessage(line: line) == nil)
    }
}

@MainActor
struct DrumMachineModelTests {
    /// Settings of its own, so the tests neither change Yafie's nor see them
    private let defaults = UserDefaults(suiteName: "yafie-test-\(UUID().uuidString)")!

    private func model() -> (DrumMachineModel, () -> [DrumCommand]) {
        let model = DrumMachineModel(defaults: defaults)
        final class Sent { var commands: [DrumCommand] = [] }
        let sent = Sent()
        model.send = { sent.commands.append($0) }
        return (model, { sent.commands })
    }

    @Test func startsAt100WithTheMetronomeOnForABar() {
        let (model, _) = model()
        #expect(model.tempo == 100 && model.isMetronomeOn && model.bars == 1 && !model.isPlaying)
    }

    @Test func tempoIsWholeBeatsFrom40To240() {
        let (model, sent) = model()
        model.setTempo(99.6)
        model.setTempo(300)
        model.setTempo(12)
        #expect(sent() == [.tempo(240), .tempo(40)])  // 99.6 is still 100
        #expect(model.tempo == 40)
        #expect(DrumMachineModel(defaults: defaults).tempo == 40)  // remembered
    }

    @Test func fourBarsRepeatTheLoop() {
        let (model, sent) = model()
        model.received(.recorded(DrumNote(pad: .kick, step: 0)))
        model.bars = 4
        #expect(model.pattern.count == 4)
        #expect(sent() == [.bars(4)])
    }

    @Test func aNewPlayerIsToldEverything() {
        let (model, sent) = model()
        model.received(.recorded(DrumNote(pad: .snare, step: 4)))
        model.togglePlay()
        model.playerStarted()
        #expect(sent() == [.play, .tempo(100), .metronome(true), .bars(1), .load([DrumNote(pad: .snare, step: 4)]),
                           .play])
    }

    @Test func beatsShowOnlyWhilePlaying() {
        let (model, _) = model()
        model.received(.beat(bar: 1, beat: 2, phase: .playing))
        #expect(model.beat == nil)
        model.record()
        model.received(.beat(bar: 0, beat: 1, phase: .countIn))
        #expect(model.phase == .countIn)
        model.togglePlay()
        #expect(model.beat == nil && !model.isPlaying)
    }

    @Test func clearEmptiesTheLoop() {
        let (model, sent) = model()
        model.received(.recorded(DrumNote(pad: .kick, step: 0)))
        model.clear()
        #expect(model.pattern.isEmpty && sent() == [.clear])
    }
}

/// Shell scripts stand in for the player, so these make no sound
@MainActor
struct DrumAudioTests {
    final class Recorder {
        var statuses: [DrumAudio.Status] = []
        var messages: [DrumMessage] = []
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("yafie-test-\(UUID().uuidString)")

        var written: String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
    }

    private func audio(_ script: String, _ recorder: Recorder) -> DrumAudio {
        let player = DrumAudio.Player(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        return DrumAudio(player: player, silenceLimit: 2, settleTime: 0.1,
                         onStatus: { recorder.statuses.append($0) }, onMessage: { recorder.messages.append($0) })
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func commandsGoToThePlayerAndItsNewsComesBack() async {
        let recorder = Recorder()
        // Says it's ready and plays a kick, then writes down each command
        let script = "echo ready 48000; echo played kick; "
            + "while read line; do echo \"$line\" >> '\(recorder.file.path)'; done"
        let audio = audio(script, recorder)
        defer { try? FileManager.default.removeItem(at: recorder.file) }
        audio.start()
        #expect(await eventually { recorder.statuses.last == .ready })
        #expect(await eventually { recorder.messages == [.played(.kick)] })
        audio.send(.hit(.snare))
        audio.send(.tempo(90))
        #expect(await eventually { recorder.written == "hit snare\ntempo 90.0\n" })
        audio.stop()
    }

    @Test func aPlayerThatQuitsIsStartedAgain() async {
        let recorder = Recorder()
        let audio = audio("echo ready 48000; echo x >> '\(recorder.file.path)'; exit 0", recorder)
        defer { try? FileManager.default.removeItem(at: recorder.file) }
        audio.start()
        #expect(await eventually { recorder.written.split(separator: "\n").count >= 3 })
        audio.stop()
    }

    @Test func givesUpOnAPlayerThatNeverStarts() async {
        let recorder = Recorder()
        let audio = audio("exit 1", recorder)
        audio.start()
        #expect(await eventually {
            if case .failed = recorder.statuses.last { return true }
            return false
        })
        audio.stop()
    }

    @Test func sendingToAPlayerThatsGoneIsHarmless() async {
        let recorder = Recorder()
        let audio = audio("echo ready 48000; exec sleep 30", recorder)
        audio.start()
        #expect(await eventually { recorder.statuses.last == .ready })
        audio.stop()
        audio.send(.hit(.kick))  // nothing to write to, and no SIGPIPE
    }
}
