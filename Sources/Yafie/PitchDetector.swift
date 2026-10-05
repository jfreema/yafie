import Accelerate

/// A periodic sound's frequency
struct Pitch: Equatable, Sendable {
    var frequency: Double
    /// 0 to 1, how periodic the sound is
    var clarity: Float
}

/// McLeod Pitch Method: normalized square difference, first key maximum above k × highest
struct PitchDetector: Sendable {
    /// Several periods of the lowest string: 4080 samples at 48 kHz
    static let windowDuration = 0.085

    let sampleRate: Double
    let windowSize: Int
    var k: Float = 0.9
    var minFrequency = 55.0
    var maxFrequency = 1500.0
    /// Quieter than this, in dBFS, isn't worth reading
    var minLevel: Float = -60
    /// Anything less periodic isn't a note
    var minClarity: Float = 0.9

    init(sampleRate: Double, windowSize: Int? = nil) {
        self.sampleRate = sampleRate
        self.windowSize = windowSize ?? Int(sampleRate * Self.windowDuration)
    }

    func detect(_ input: [Float]) -> Pitch? {
        let w = windowSize
        guard input.count >= w else { return nil }
        var x = Array(input.suffix(w))
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(w))
        var negMean = -mean
        vDSP_vsadd(x, 1, &negMean, &x, 1, vDSP_Length(w))

        let maxLag = min(w / 2, Int(sampleRate / minFrequency) + 2)
        let minLag = max(2, Int(sampleRate / maxFrequency))
        var squares = [Float](repeating: 0, count: w)
        vDSP_vsq(x, 1, &squares, 1, vDSP_Length(w))
        var energy: Float = 0
        vDSP_sve(squares, 1, &energy, vDSP_Length(w))
        guard energy > 0, 10 * log10(energy / Float(w)) >= minLevel else { return nil }

        var nsdf = [Float](repeating: 0, count: maxLag + 1)
        var m = 2 * Double(energy)
        x.withUnsafeBufferPointer { xp in
            let base = xp.baseAddress!
            for tau in 0...maxLag {
                if tau > 0 { m -= Double(squares[tau - 1]) + Double(squares[w - tau]) }
                var r: Float = 0
                vDSP_dotpr(base, 1, base + tau, 1, &r, vDSP_Length(w - tau))
                nsdf[tau] = m > 0 ? Float(2 * Double(r) / m) : 0
            }
        }

        // Skip the lobe around zero lag, then take each positive region's maximum
        var tau = 1
        while tau < maxLag, nsdf[tau] > 0 { tau += 1 }
        var keyMaxima: [(lag: Int, value: Float)] = []
        while tau < maxLag {
            while tau < maxLag, nsdf[tau] <= 0 { tau += 1 }
            var best = tau, bestValue: Float = 0
            while tau < maxLag, nsdf[tau] > 0 {
                if nsdf[tau] > bestValue { best = tau; bestValue = nsdf[tau] }
                tau += 1
            }
            if bestValue > 0, best >= minLag, best < maxLag { keyMaxima.append((best, bestValue)) }
        }
        guard let highest = keyMaxima.map(\.value).max(),
              let chosen = keyMaxima.first(where: { $0.value >= k * highest }) else { return nil }

        // Parabola through the peak and its neighbours
        let t = chosen.lag
        let a = nsdf[t - 1], b = nsdf[t], c = nsdf[t + 1]
        let denominator = a - 2 * b + c
        let delta = denominator == 0 ? 0 : 0.5 * (a - c) / denominator
        let clarity = b - 0.25 * (a - c) * delta
        guard clarity >= minClarity else { return nil }
        return Pitch(frequency: sampleRate / (Double(t) + Double(delta)), clarity: clarity)
    }
}

/// The nearest note to a pitch, and how far off it is
struct Note: Equatable, Sendable {
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static let a4 = 440.0

    /// MIDI numbering: 69 is A4, 60 middle C
    let number: Int
    /// −50 to +50
    let cents: Double

    var name: String { Self.names[(number % 12 + 12) % 12] }
    var octave: Int { Int((Double(number) / 12).rounded(.down)) - 1 }

    /// From a fractional MIDI number
    init(midi: Double) {
        number = Int(midi.rounded())
        cents = (midi - Double(number)) * 100
    }

    init(frequency: Double) { self.init(midi: Self.midi(for: frequency)) }

    static func midi(for frequency: Double) -> Double { 69 + 12 * log2(frequency / a4) }
    static func frequency(for midi: Double) -> Double { a4 * pow(2, (midi - 69) / 12) }
}
