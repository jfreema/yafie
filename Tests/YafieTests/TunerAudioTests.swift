import Foundation
import Testing
@testable import Yafie

struct ListenerMessageTests {
    @Test(arguments: [
        ListenerMessage.listening(device: "MacBook Air Microphone", sampleRate: 48000, channels: 1),
        .heard(Heard(pitch: Pitch(frequency: 110.25, clarity: 0.97), level: -31.5)),
        .heard(Heard(level: -120)),
        .changed,
        .noInput,
        .failed("The operation couldn’t be completed. (OSStatus error 2003329396.)"),
    ])
    func roundTrip(message: ListenerMessage) {
        #expect(ListenerMessage(line: message.line) == message)
    }

    @Test func oneLineEach() {
        #expect(ListenerMessage.failed("two\nlines").line == "failed two lines")
    }

    @Test(arguments: ["", "heard", "heard -30", "heard x -", "heard -30 110", "heard -30 x 0.9", "listening 48000", "changed now", "hello"])
    func ignoresGarbage(line: String) {
        #expect(ListenerMessage(line: line) == nil)
    }
}

/// Shell scripts stand in for the listener, so these run without a microphone
@MainActor
struct TunerAudioTests {
    final class Recorder {
        var statuses: [TunerAudio.Status] = []
        var pitches: [Pitch?] = []
        var levels: [Float] = []
        /// Each stand-in writes its process ID here
        let pids = FileManager.default.temporaryDirectory.appendingPathComponent("yafie-test-\(UUID().uuidString)")

        var launched: [Int32] {
            ((try? String(contentsOf: pids, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int32($0) }
        }
    }

    private func audio(_ script: String, _ recorder: Recorder) -> TunerAudio {
        let listener = TunerAudio.Listener(executable: URL(fileURLWithPath: "/bin/sh"),
                                           arguments: ["-c", "echo $$ >> '\(recorder.pids.path)'; \(script)"])
        return TunerAudio(listener: listener, silenceLimit: 0.4, settleTime: 0.1,
                          onStatus: { recorder.statuses.append($0) }, onHeard: { recorder.pitches.append($0.pitch); recorder.levels.append($0.level) })
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func allGone(_ pids: [Int32]) async -> Bool {
        await eventually { pids.allSatisfy { kill($0, 0) != 0 } }
    }

    @Test func reportsWhatItHears() async {
        let recorder = Recorder()
        let audio = audio("echo 'listening 48000.0 1 Test Mic'; while :; do echo 'heard -30.0 110.0 0.99'; sleep 0.02; done", recorder)
        audio.listen()
        #expect(await eventually { recorder.pitches.count >= 3 })
        #expect(recorder.statuses == [.listening])
        #expect(recorder.pitches.last == Pitch(frequency: 110, clarity: 0.99))
        #expect(recorder.levels.last == -30)
        audio.stop()
        #expect(recorder.launched.count == 1)
        #expect(await allGone(recorder.launched))
    }

    @Test func givesUpOnAStuckListener() async {
        let recorder = Recorder()
        let audio = audio("exec sleep 30", recorder)
        audio.listen()
        #expect(await eventually { recorder.statuses.last == .failed("The audio input isn't responding. Try again, or choose another input in System Settings → Sound.") })
        #expect(recorder.launched.count == 2)  // one retry
        #expect(await allGone(recorder.launched))
        audio.stop()
    }

    @Test func startsOverWhenTheInputChanges() async {
        let recorder = Recorder()
        let audio = audio("echo 'listening 48000.0 1 Test Mic'; echo 'heard -80.0 -'; echo changed; exec sleep 30", recorder)
        audio.listen()
        #expect(await eventually { recorder.launched.count >= 3 })
        audio.stop()
        #expect(recorder.statuses.starts(with: [.listening, .starting, .listening]))
        #expect(!recorder.statuses.contains { if case .failed = $0 { true } else { false } })
        #expect(await allGone(recorder.launched))
    }

    @Test func givesUpWhenTheInputKeepsChangingBeforeAnySound() async {
        let recorder = Recorder()
        let audio = audio("echo 'listening 48000.0 1 Test Mic'; echo changed; exec sleep 30", recorder)
        audio.listen()
        #expect(await eventually { recorder.statuses.last == .failed("The audio input keeps changing. Try again, or choose another input in System Settings → Sound.") })
        #expect(recorder.launched.count == 2)
        #expect(await allGone(recorder.launched))
        audio.stop()
    }

    @Test func reportsNoInput() async {
        let recorder = Recorder()
        let audio = audio("echo noinput; exec sleep 30", recorder)
        audio.listen()
        #expect(await eventually { recorder.statuses.last == .noInput })
        #expect(recorder.launched.count == 1)
        #expect(await allGone(recorder.launched))
        audio.stop()
    }

    @Test func retriesAListenerThatQuits() async {
        let recorder = Recorder()
        let audio = audio("echo 'listening 48000.0 1 Test Mic'", recorder)
        audio.listen()
        #expect(await eventually { recorder.statuses.last == .failed("The audio input stopped. Try again, or choose another input in System Settings → Sound.") })
        #expect(recorder.launched.count == 2)
        audio.stop()
    }

    @Test func ignoresAnEndedListener() async {
        let recorder = Recorder()
        let audio = audio("echo 'listening 48000.0 1 Test Mic'; while :; do echo 'heard -30.0 110.0 0.99'; sleep 0.02; done", recorder)
        audio.listen()
        #expect(await eventually { !recorder.pitches.isEmpty })
        audio.stop()
        let heard = recorder.pitches.count
        try? await Task.sleep(for: .milliseconds(200))
        #expect(recorder.pitches.count == heard)
    }
}
