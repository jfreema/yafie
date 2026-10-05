import Foundation

/// Test sounds with known pitch
enum Signal {
    /// Repeatable noise and phases
    struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    /// Partial n at n·f·√(1 + B·n²) with a random phase, plus uniform noise at the given RMS
    static func tone(_ frequency: Double, sampleRate: Double, count: Int, partials: [Double] = [1],
                     inharmonicity b: Double = 0, noise: Double = 0, amplitude: Double = 1, seed: UInt64 = 7) -> [Float] {
        var random = Random(state: seed)
        var out = [Float](repeating: 0, count: count)
        for (index, level) in partials.enumerated() where level > 0 {
            let n = Double(index + 1)
            let step = 2 * Double.pi * n * frequency * (1 + b * n * n).squareRoot() / sampleRate
            let phase = Double.random(in: 0..<(2 * .pi), using: &random)
            for t in 0..<count { out[t] += Float(amplitude * level * sin(step * Double(t) + phase)) }
        }
        if noise > 0 {
            let peak = noise * 3.0.squareRoot()
            for t in 0..<count { out[t] += Float(Double.random(in: -peak...peak, using: &random)) }
        }
        return out
    }

    static func noise(rms: Double, count: Int, seed: UInt64 = 7) -> [Float] {
        tone(0, sampleRate: 1, count: count, partials: [], noise: rms, seed: seed)
    }

    /// Karplus–Strong pluck, `start` samples in. This form's loop delay is n − 0.5 samples, which gives its exact frequency.
    static func pluck(_ frequency: Double, sampleRate: Double, start: Int, count: Int,
                      seed: UInt64 = 7) -> (samples: [Float], frequency: Double) {
        let n = Int((sampleRate / frequency + 0.5).rounded())
        var random = Random(state: seed)
        var line = (0..<n).map { _ in Float.random(in: -1...1, using: &random) }
        var out = [Float](repeating: 0, count: start + count)
        var i = 0
        for t in 0..<(start + count) {
            let next = (i + 1) % n
            out[t] = line[i]
            line[i] = 0.998 * 0.5 * (line[i] + line[next])
            i = next
        }
        return (Array(out.suffix(count)), sampleRate / (Double(n) - 0.5))
    }
}

/// How far a measurement is from the truth
func cents(_ measured: Double, from truth: Double) -> Double { 1200 * log2(measured / truth) }
