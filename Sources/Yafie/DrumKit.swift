import Accelerate
import Foundation

/// The drum machine's sounds, made when the player starts, so there are no sound files to ship. Mono, from −1 to 1,
/// each scaled to its loudest: the drums near full scale, the metronome well under them.
enum DrumKit {
    /// In DrumSound's order
    static func sounds(sampleRate: Double) -> [[Float]] {
        DrumSound.allCases.map { sound in
            switch sound {
            case .kick: kick(sampleRate)
            case .snare: snare(sampleRate)
            case .hiHat: hiHat(sampleRate)
            case .click: click(sampleRate, pitch: 850, peak: 0.25)
            case .accent: click(sampleRate, pitch: 1350, peak: 0.33)
            }
        }
    }

    /// A big, open kick, like John Bonham's 26-inch: a deep boom that rings on as its pitch settles, the shell's
    /// overtone, a knock for punch and the felt beater's thud, warmed up like tape and played in a big room
    static func kick(_ rate: Double) -> [Float] {
        var phase = 0.0
        var noise = Noise(seed: 0xB0)
        var felt = 0.0
        let dry = samples(seconds: 0.9, rate) { t in
            phase += 2 * .pi * (50 + 45 * exp(-t / 0.06)) / rate
            let boom = sin(phase) * exp(-t / 0.32)
            let shell = 0.4 * sin(1.59 * phase) * exp(-t / 0.15)
            // What laptop speakers can play, so it doesn't vanish on them
            let knock = 0.7 * sin(2 * .pi * 150 * t) * exp(-t / 0.04)
            felt += 0.6 * (noise.next() - felt)  // a felt beater's slap, not a click
            let thud = 1.2 * felt * exp(-t / 0.006)
            return saturated(boom + shell + knock + thud, drive: 1.8)
        }
        return finished(room(dry, rate), rate, peak: 0.95)
    }

    /// The drum's tone under the rattle of its snares, which is noise with the lows taken out, pushed hard so it cracks
    static func snare(_ rate: Double) -> [Float] {
        var noise = Noise(seed: 0x5EED)
        var last = 0.0
        return finished(samples(seconds: 0.25, rate) { t in
            let white = noise.next()
            let rattle = 0.5 * (white - last) * exp(-t / 0.07)
            last = white
            let tone = 0.55 * sin(2 * .pi * 185 * t) * exp(-t / 0.05) + 0.25 * sin(2 * .pi * 330 * t) * exp(-t / 0.03)
            return saturated(rattle + tone, drive: 1.5)
        }, rate, peak: 0.85)
    }

    /// Noise with the lows taken out twice, so it hisses, closed and short
    static func hiHat(_ rate: Double) -> [Float] {
        var noise = Noise(seed: 0x4A7)
        var last = 0.0, lastBright = 0.0
        return finished(samples(seconds: 0.12, rate) { t in
            let white = noise.next()
            let bright = white - last
            let brighter = bright - lastBright
            (last, lastBright) = (white, bright)
            return saturated(brighter * exp(-t / 0.025), drive: 1)
        }, rate, peak: 0.6)
    }

    static func click(_ rate: Double, pitch: Double, peak: Double) -> [Float] {
        finished(samples(seconds: 0.03, rate) { t in sin(2 * .pi * pitch * t) * exp(-t / 0.008) }, rate, peak: peak)
    }

    /// A sample at each moment
    private static func samples(seconds: Double, _ rate: Double, _ sample: (Double) -> Double) -> [Double] {
        (0..<Int(seconds * rate)).map { sample(Double($0) / rate) }
    }

    /// Squashes the peaks, so a sound scaled to the same peak is fuller and louder
    private static func saturated(_ sample: Double, drive: Double) -> Double { tanh(drive * sample) / tanh(drive) }

    /// Reflections off the walls of a big room, each later one softer and duller
    private static func room(_ dry: [Double], _ rate: Double) -> [Double] {
        var wet = dry
        for (delay, gain) in [(0.011, 0.35), (0.019, 0.27), (0.029, 0.2), (0.043, 0.14), (0.061, 0.1)] {
            let offset = Int(delay * rate)
            var dull = 0.0
            for index in offset..<dry.count {
                dull += 0.3 * (dry[index - offset] - dull)  // the walls soak up the highs
                wet[index] += gain * dull
            }
        }
        return wet
    }

    /// Scaled so its loudest sample is `peak`, with a short fade at the end so it stops without a click
    private static func finished(_ samples: [Double], _ rate: Double, peak: Double) -> [Float] {
        let loudest = samples.map(abs).max() ?? 0
        let scale = loudest > 0 ? peak / loudest : 0
        let fade = Double(max(1, Int(0.005 * rate)))
        return samples.indices.map { index in
            Float(samples[index] * scale * min(1, Double(samples.count - index) / fade))
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

    init(sounds: [[Float]], gain: Float = 1) {
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
        // Hits on top of each other can add up past full scale. Past 0.8 they're eased in under 1, which is gentler on
        // the ear than cutting them off.
        for index in 0..<frames {
            let sample = output[index] * gain
            let size = abs(sample)
            guard size > 0.8 else {
                output[index] = sample
                continue
            }
            output[index] = (0.8 + 0.2 * tanh((size - 0.8) / 0.2)) * (sample < 0 ? -1 : 1)
        }
    }
}
