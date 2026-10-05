import AVFoundation
import Testing
@testable import Yafie

struct PitchAnalyzerTests {
    private let sampleRate = 48000.0

    /// Cuts each channel's samples into buffers, as AVAudioEngine delivers them
    private func buffers(_ channels: [[Float]], frames: Int) -> [AVAudioPCMBuffer] {
        // A layout, since past two channels a format needs one
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels.count))!
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
        return stride(from: 0, to: channels[0].count, by: frames).map { start in
            let count = min(frames, channels[0].count - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for (index, samples) in channels.enumerated() {
                for frame in 0..<count { buffer.floatChannelData![index][frame] = samples[start + frame] }
            }
            return buffer
        }
    }

    @Test func waitsForAFullWindow() {
        let analyzer = PitchAnalyzer(sampleRate: sampleRate)
        let tone = Signal.tone(110, sampleRate: sampleRate, count: 2048)
        #expect(buffers([tone], frames: 2048).map { analyzer.process($0).pitch } == [nil])
    }

    @Test func readsAcrossBuffers() throws {
        let analyzer = PitchAnalyzer(sampleRate: sampleRate)
        let tone = Signal.tone(110, sampleRate: sampleRate, count: 6 * 1024, partials: [0.4, 1, 0.8, 0.5])
        let pitch = try #require(buffers([tone], frames: 1024).map { analyzer.process($0).pitch }.last ?? nil)
        #expect(abs(cents(pitch.frequency, from: 110)) < 1)
    }

    @Test func followsTheLoudestChannel() throws {
        let analyzer = PitchAnalyzer(sampleRate: sampleRate)
        let count = 6 * 1024
        let hiss = Signal.noise(rms: 0.001, count: count)
        let guitar = Signal.tone(196, sampleRate: sampleRate, count: count, partials: [0.4, 1, 0.8, 0.5])
        let pitch = try #require(buffers([hiss, guitar], frames: 1024).map { analyzer.process($0).pitch }.last ?? nil)
        #expect(abs(cents(pitch.frequency, from: 196)) < 1)
    }

    @Test func ignoresChannelsPastTheSecond() throws {
        let analyzer = PitchAnalyzer(sampleRate: sampleRate)
        let count = 6 * 1024
        let hiss = Signal.noise(rms: 0.001, count: count)
        let guitar = Signal.tone(196, sampleRate: sampleRate, count: count, partials: [0.4, 1, 0.8, 0.5], amplitude: 0.1)
        // An interface's loopback, carrying the Mac's own sound, much louder
        let loopback = Signal.tone(440, sampleRate: sampleRate, count: count, amplitude: 0.9)
        let pitch = try #require(buffers([hiss, guitar, loopback], frames: 1024).map { analyzer.process($0).pitch }.last ?? nil)
        #expect(abs(cents(pitch.frequency, from: 196)) < 1)
    }

    @Test func reportsTheLevelFromTheStart() throws {
        let analyzer = PitchAnalyzer(sampleRate: sampleRate)
        // RMS of a sine is its amplitude ÷ √2: 0.1 is −23 dBFS
        let tone = Signal.tone(110, sampleRate: sampleRate, count: 1024, amplitude: 0.1)
        let heard = try #require(buffers([tone], frames: 1024).first.map(analyzer.process))
        #expect(heard.pitch == nil)  // window still filling
        #expect(abs(heard.level + 23.01) < 0.3)
    }

    @Test func silenceHasTheFloorLevel() throws {
        let analyzer = PitchAnalyzer(sampleRate: sampleRate)
        let heard = try #require(buffers([[Float](repeating: 0, count: 1024)], frames: 1024).first.map(analyzer.process))
        #expect(heard.level == Heard.silence)
    }
}
