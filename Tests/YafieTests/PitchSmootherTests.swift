import Testing
@testable import Yafie

struct PitchSmootherTests {
    @Test func showsTheFirstEstimateRightAway() {
        var smoother = PitchSmoother()
        #expect(smoother.update(midi: 45, at: 0) == .init(midi: 45, isHeld: false))
    }

    @Test func nothingHeardShowsNothing() {
        var smoother = PitchSmoother()
        #expect(smoother.update(midi: nil, at: 0) == nil)
    }

    @Test func medianIgnoresAnOutlier() {
        var smoother = PitchSmoother()
        let shown = [45.0, 45.02, 57, 44.98, 45.01].enumerated().map { index, estimate in
            smoother.update(midi: estimate, at: Double(index) * 0.05)?.midi
        }
        #expect(shown.allSatisfy { abs(($0 ?? 0) - 45) < 0.1 })
    }

    @Test func octaveJumpWaitsForThreeInARow() {
        var smoother = PitchSmoother()
        var time = 0.0
        func feed(_ midi: Double) -> Double? {
            time += 0.05
            return smoother.update(midi: midi, at: time)?.midi
        }
        for _ in 0..<5 { _ = feed(45) }
        #expect(feed(57) == 45)
        #expect(feed(45) == 45)
        #expect(feed(57) == 45)
        #expect(feed(57) == 45)  // the median says 57, but only two in a row
        #expect(feed(57) == 57)
    }

    @Test func holdsTheLastReadingForASecond() {
        var smoother = PitchSmoother()
        _ = smoother.update(midi: 45, at: 0)
        #expect(smoother.update(midi: nil, at: 0.5) == .init(midi: 45, isHeld: true))
        #expect(smoother.update(midi: nil, at: 1.2) == nil)
    }

    @Test func startsFreshAfterTheHold() {
        var smoother = PitchSmoother()
        for index in 0..<5 { _ = smoother.update(midi: 45, at: Double(index) * 0.05) }
        _ = smoother.update(midi: nil, at: 2)
        #expect(smoother.update(midi: 57, at: 2.05)?.midi == 57)  // no octave guard against the old note
    }
}

struct LoudnessMeterTests {
    @Test func belowSoftIsQuiet() {
        var meter = LoudnessMeter()
        #expect(meter.update(-70, at: 0) == .quiet)
        #expect(meter.update(Heard.silence, at: 0.04) == .quiet)
    }

    @Test(arguments: [(Float(-45), LoudnessMeter.Loudness.soft), (-35, .medium), (-25, .loud), (-10, .veryLoud)])
    func bands(level: Float, loudness: LoudnessMeter.Loudness) {
        var meter = LoudnessMeter()
        #expect(meter.update(level, at: 0) == loudness)
    }

    @Test func fallsBackSlowly() {
        var meter = LoudnessMeter()
        #expect(meter.update(-10, at: 0) == .veryLoud)
        #expect(meter.update(-90, at: 0.1) == .veryLoud)  // −13
        #expect(meter.update(-90, at: 0.5) == .loud)      // −25
        #expect(meter.update(-90, at: 1) == .medium)      // −40
        #expect(meter.update(-90, at: 1.5) == .soft)      // −55
        #expect(meter.update(-90, at: 2) == .quiet)       // −70
    }

    @Test func louderSoundJumpsStraightUp() {
        var meter = LoudnessMeter()
        #expect(meter.update(-45, at: 0) == .soft)
        #expect(meter.update(-5, at: 0.04) == .veryLoud)
    }
}

