import Accelerate
import Foundation

/// The drum machine's sounds, made when the player starts, so there are no sound files to ship. Mono, from −1 to 1.
enum DrumKit {
    /// In DrumSound's order
    static func sounds(sampleRate: Double) -> [[Float]] {
        DrumSound.allCases.map { sound in
            switch sound {
            case .kick: kick(sampleRate)
            case .snare: snare(sampleRate)
            case .hiHat: hiHat(sampleRate)
            case .click: click(sampleRate, pitch: 1000, level: 0.45)
            case .accent: click(sampleRate, pitch: 1600, level: 0.6)
            }
        }
    }

    /// A sine that drops fast in pitch, which gives the thump, and a little click for the beater
    static func kick(_ rate: Double) -> [Float] {
        var phase = 0.0
        return shaped(seconds: 0.45, rate) { t in
            phase += 2 * .pi * (48 + 110 * exp(-t / 0.035)) / rate
            let beater = t < 0.003 ? 0.3 * (1 - t / 0.003) : 0
            return 0.8 * sin(phase) * exp(-t / 0.16) + beater
        }
    }

    /// The drum's tone under the rattle of its snares, which is noise with the lows taken out
    static func snare(_ rate: Double) -> [Float] {
        var noise = Noise(seed: 0x5EED)
        var last = 0.0
        return shaped(seconds: 0.25, rate) { t in
            let white = noise.next()
            let rattle = 0.3 * (white - last) * exp(-t / 0.07)
            last = white
            let tone = 0.55 * sin(2 * .pi * 185 * t) * exp(-t / 0.05) + 0.25 * sin(2 * .pi * 330 * t) * exp(-t / 0.03)
            // Never past full scale: the rattle's at most 0.6 and the tone 0.8
            return 0.7 * (rattle + tone)
        }
    }

    /// Noise with the lows taken out twice, so it hisses, closed and short
    static func hiHat(_ rate: Double) -> [Float] {
        var noise = Noise(seed: 0x4A7)
        var last = 0.0, lastBright = 0.0
        return shaped(seconds: 0.12, rate) { t in
            let white = noise.next()
            let bright = white - last
            let brighter = bright - lastBright
            (last, lastBright) = (white, bright)
            return 0.25 * brighter * exp(-t / 0.025)  // at most 1
        }
    }

    static func click(_ rate: Double, pitch: Double, level: Double) -> [Float] {
        shaped(seconds: 0.03, rate) { t in level * sin(2 * .pi * pitch * t) * exp(-t / 0.008) }
    }

    /// A sample at each moment, with a short fade at the end so it stops without a click
    private static func shaped(seconds: Double, _ rate: Double, _ sample: (Double) -> Double) -> [Float] {
        let count = Int(seconds * rate)
        let fade = Int(0.005 * rate)
        return (0..<count).map { index in
            let tail = min(1, Double(count - index) / Double(max(fade, 1)))
            return Float(sample(Double(index) / rate) * tail)
        }
    }

    /// The same noise every time, so the sounds don't change between runs
    private struct Noise {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        /// From −1 to 1
        mutating func next() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state >> 11) / Double(1 << 52) - 1
        }
    }
}

/// Plays the kit's sounds into the audio thread's buffers, several at once. It doesn't allocate once it's playing.
struct DrumMixer {
    static let voices = 24

    private let sounds: [[Float]]
    /// What's sounding: which sound, and the sample of it that goes at the next buffer's start. A sound that starts
    /// partway into the buffer begins below zero.
    private var playing: [(sound: Int, position: Int)] = []
    private let gain: Float

    init(sounds: [[Float]], gain: Float = 0.8) {
        self.sounds = sounds
        self.gain = gain
        playing.reserveCapacity(Self.voices)
    }

    var isSilent: Bool { playing.isEmpty }

    /// Starts the events at their offsets, then mixes everything sounding into `output`, which it overwrites
    mutating func mix(_ frames: Int, starting events: [DrumSequencer.Event], into output: UnsafeMutablePointer<Float>) {
        for event in events {
            if playing.count == Self.voices { playing.removeFirst() }  // the oldest stops
            playing.append((event.sound.rawValue, -event.offset))
        }
        vDSP_vclr(output, 1, vDSP_Length(frames))
        for index in playing.indices {
            let (sound, position) = playing[index]
            let start = max(0, -position)
            let from = max(0, position)
            let count = min(frames - start, sounds[sound].count - from)
            if count > 0 {
                sounds[sound].withUnsafeBufferPointer { samples in
                    vDSP_vadd(output + start, 1, samples.baseAddress! + from, 1, output + start, 1, vDSP_Length(count))
                }
            }
            playing[index].position += frames
        }
        playing.removeAll { $0.position >= sounds[$0.sound].count }
        var gain = gain, low: Float = -1, high: Float = 1
        vDSP_vsmul(output, 1, &gain, output, 1, vDSP_Length(frames))
        // Hits on top of each other can add up past full scale
        vDSP_vclip(output, 1, &low, &high, output, 1, vDSP_Length(frames))
    }
}
