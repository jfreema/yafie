import Foundation
import Testing
@testable import Yafie

/// Second harmonic louder than the fundamental, as on a guitar's low strings
private let guitar = [0.4, 1, 0.8, 0.5, 0.35, 0.25, 0.15, 0.1]
private let openStrings = [82.407, 110, 146.832, 195.998, 246.942, 329.628]

struct PitchDetectorTests {
    let detector = PitchDetector(sampleRate: 48000)

    @Test(arguments: openStrings, [0, 7.3, -23])
    func openString(frequency: Double, offset: Double) throws {
        let truth = frequency * pow(2, offset / 1200)
        let samples = Signal.tone(truth, sampleRate: 48000, count: detector.windowSize, partials: guitar, noise: 0.05)
        let pitch = try #require(detector.detect(samples))
        #expect(abs(cents(pitch.frequency, from: truth)) < 1)
    }

    @Test(arguments: [73.416, 659.255, 1000])
    func edgesOfTheRange(frequency: Double) throws {
        let samples = Signal.tone(frequency, sampleRate: 48000, count: detector.windowSize)
        let pitch = try #require(detector.detect(samples))
        #expect(abs(cents(pitch.frequency, from: frequency)) < 1)
    }

    @Test(arguments: [82.407, 195.998, 329.628])
    func pluckedString(frequency: Double) throws {
        let pluck = Signal.pluck(frequency, sampleRate: 48000, start: 9600, count: detector.windowSize)
        let pitch = try #require(detector.detect(pluck.samples))
        #expect(abs(cents(pitch.frequency, from: pluck.frequency)) < 0.1)
    }

    @Test(arguments: [16000.0, 44100, 96000])
    func otherSampleRates(sampleRate: Double) throws {
        let detector = PitchDetector(sampleRate: sampleRate)
        let samples = Signal.tone(110, sampleRate: sampleRate, count: detector.windowSize, partials: guitar, noise: 0.05)
        let pitch = try #require(detector.detect(samples))
        #expect(abs(cents(pitch.frequency, from: 110)) < 1)
    }

    @Test func silenceIsNothing() {
        #expect(detector.detect([Float](repeating: 0, count: detector.windowSize)) == nil)
    }

    @Test func tooQuietIsNothing() {
        // A sine's RMS is its amplitude ÷ √2: −70 and −50 dBFS
        let faint = Signal.tone(110, sampleRate: 48000, count: detector.windowSize, amplitude: 0.000447)
        let soft = Signal.tone(110, sampleRate: 48000, count: detector.windowSize, amplitude: 0.00447)
        #expect(detector.detect(faint) == nil)
        #expect(detector.detect(soft) != nil)
    }

    @Test func noiseIsNothing() {
        #expect(detector.detect(Signal.noise(rms: 0.3, count: detector.windowSize)) == nil)
    }

    @Test func shortInputIsNothing() {
        #expect(detector.detect(Signal.tone(110, sampleRate: 48000, count: 100)) == nil)
    }
}

struct NoteTests {
    @Test func concertA() {
        let note = Note(frequency: 440)
        #expect(note.name == "A")
        #expect(note.octave == 4)
        #expect(abs(note.cents) < 1e-9)
    }

    @Test func openStringNames() {
        let names = openStrings.map { frequency -> String in
            let note = Note(frequency: frequency)
            return "\(note.name)\(note.octave)"
        }
        #expect(names == ["E2", "A2", "D3", "G3", "B3", "E4"])
    }

    @Test func octaveStartsAtC() {
        #expect(Note(frequency: 246.942).octave == 3)  // B3
        #expect(Note(frequency: 261.626).octave == 4)  // middle C
        #expect(Note(frequency: 261.626).name == "C")
    }

    @Test func sharpAndFlat() {
        #expect(abs(Note(frequency: 450).cents - 38.9) < 0.1)
        #expect(abs(Note(frequency: 430).cents + 39.8) < 0.1)
        #expect(Note(frequency: 450).name == "A")
        #expect(Note(frequency: 277.183).name == "C♯")
    }

    @Test func roundTrip() {
        #expect(abs(Note.frequency(for: Note.midi(for: 123.4)) - 123.4) < 1e-9)
    }
}
