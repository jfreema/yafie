import CoreGraphics

/// A drum the pads play
enum DrumPad: String, CaseIterable, Sendable {
    case kick, snare, hiHat = "hihat"

    /// Where a finger lands on the trackpad, or a click on the pads, 0 to 1 across and up from the bottom left: the
    /// snare top left, the kick top right, and a hi-hat anywhere along the bottom
    init(at point: CGPoint) {
        self = point.y < 0.5 ? .hiHat : point.x < 0.5 ? .snare : .kick
    }

    var name: String {
        switch self {
        case .kick: "Kick"
        case .snare: "Snare"
        case .hiHat: "Hi-Hat"
        }
    }

    var sound: DrumSound {
        switch self {
        case .kick: .kick
        case .snare: .snare
        case .hiHat: .hiHat
        }
    }
}

/// A sound the player makes: the drums, and the metronome's click, higher on each bar's first beat
enum DrumSound: Int, CaseIterable, Sendable {
    case kick, snare, hiHat, click, accent
}

/// A hit in the loop: which drum, and which sixteenth note of the loop
struct DrumNote: Hashable, Sendable {
    var pad: DrumPad
    var step: Int
}

/// The drum machine's clock: the metronome, and a loop of a bar or four, counted in sixteenth notes. Pure, so it's
/// tested. The player's audio thread moves it on a buffer at a time.
struct DrumSequencer {
    /// A sound to start, so many frames into the buffer
    struct Event: Equatable, Sendable {
        var sound: DrumSound
        var offset: Int
    }

    /// What the app hears about
    enum Report: Equatable, Sendable {
        /// A beat starts. Bar 0 is the count-in.
        case beat(bar: Int, beat: Int, phase: Phase)
        /// The loop played a hit
        case played(DrumPad)
        /// A hit joined the loop
        case recorded(DrumNote)
    }

    enum Phase: String, Sendable {
        case countIn = "count", recording = "record", playing = "play"
    }

    static let stepsPerBeat = 4
    static let stepsPerBar = 16
    static let tempos: ClosedRange<Double> = 40...240
    private static let pads = DrumPad.allCases

    let sampleRate: Double
    /// Beats a minute
    var tempo: Double = 120 {
        didSet {
            tempo = min(max(tempo, Self.tempos.lowerBound), Self.tempos.upperBound)
            // The clock keeps its place
            origin += Double(frames * Self.stepsPerBeat) * oldValue / (sampleRate * 60)
            frames = 0
        }
    }
    var isMetronomeOn = true
    /// 1 or 4
    private(set) var bars = 1
    private(set) var pattern: Set<DrumNote> = []
    private(set) var isPlaying = false
    /// Where the clock was, in sixteenths, when it started or last changed tempo, and the frames since. Counting whole
    /// frames keeps it exact, where adding up each buffer's share of a sixteenth would drift.
    private var origin: Double = 0
    private var frames = 0
    /// The next sixteenth to sound
    private var next = 0
    /// One pass round the loop, being recorded
    private var recording: Range<Int>?
    /// Hits just played live and recorded at a step still to come, so the loop doesn't play them a second time
    private var heardLive: [(pad: DrumPad, step: Int)] = []

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        // So the audio thread doesn't allocate
        pattern.reserveCapacity(4 * Self.stepsPerBar * Self.pads.count)
        heardLive.reserveCapacity(32)
    }

    var loopSteps: Int { bars * Self.stepsPerBar }
    var framesPerStep: Double { sampleRate * 60 / tempo / Double(Self.stepsPerBeat) }
    var isRecording: Bool { recording != nil }
    /// Sixteenths since the loop first started, below zero during the count-in
    var position: Double { origin + Double(frames) / framesPerStep }

    /// From the loop's start
    mutating func play() {
        guard !isPlaying else { return }
        start(at: 0)
    }

    private mutating func start(at step: Int) {
        isPlaying = true
        origin = Double(step)
        frames = 0
        next = step
    }

    mutating func stop() {
        isPlaying = false
        recording = nil
        heardLive.removeAll(keepingCapacity: true)
    }

    /// Records one pass round the loop: from here if it's playing, or else from the loop's start after a bar's
    /// count-in
    mutating func record() {
        guard recording == nil else { return }
        if isPlaying {
            let start = Int(position.rounded(.down))
            recording = start..<(start + loopSteps)
        } else {
            start(at: -Self.stepsPerBar)
            recording = 0..<loopSteps
        }
    }

    mutating func clear() {
        pattern.removeAll(keepingCapacity: true)
        heardLive.removeAll(keepingCapacity: true)
    }

    /// One bar or four. Going to four repeats the bar, and going to one keeps the first.
    mutating func setBars(_ newBars: Int) {
        guard newBars != bars, newBars == 1 || newBars == 4 else { return }
        pattern = Self.resized(pattern, from: bars, to: newBars)
        bars = newBars
        recording = nil
    }

    static func resized(_ pattern: Set<DrumNote>, from old: Int, to new: Int) -> Set<DrumNote> {
        let steps = new * stepsPerBar
        guard new > old else { return pattern.filter { $0.step < steps } }
        return Set(pattern.flatMap { note in
            stride(from: note.step, to: steps, by: old * stepsPerBar).map { DrumNote(pad: note.pad, step: $0) }
        })
    }

    /// The loop as it was, when the player starts over
    mutating func load(_ notes: Set<DrumNote>) {
        pattern = notes.filter { (0..<loopSteps).contains($0.step) }
    }

    /// A hit played live sounds right away. While recording, it joins the loop at the nearest sixteenth.
    /// - Parameter latency: frames between making a sound and hearing it
    mutating func hit(_ pad: DrumPad, latency: Double, events: inout [Event], reports: inout [Report]) {
        events.append(Event(sound: pad.sound, offset: 0))
        guard isPlaying, let recording else { return }
        // Where the clock was when the player heard what they played along to
        let step = Int((position - latency / framesPerStep).rounded())
        // A pass's last downbeat counts too, played a little early or late
        guard step >= recording.lowerBound, step <= recording.upperBound else { return }
        let note = DrumNote(pad: pad, step: (step % loopSteps + loopSteps) % loopSteps)
        if pattern.insert(note).inserted { reports.append(.recorded(note)) }
        if step >= next, heardLive.count < heardLive.capacity { heardLive.append((pad, step)) }
    }

    /// Moves the clock on by `frames`, adding the clicks and the loop's hits that start in them
    mutating func advance(_ count: Int, events: inout [Event], reports: inout [Report]) {
        guard isPlaying, count > 0 else { return }
        let perStep = framesPerStep
        let end = frames + count
        // Each sixteenth sounds on a whole frame, in whichever buffer that falls in
        while case let at = Int(((Double(next) - origin) * perStep).rounded(.up)), at < end {
            fire(next, at: max(0, at - frames), events: &events, reports: &reports)
            next += 1
        }
        frames = end
        // A step's grace, for a late hit on the next pass's first beat
        if let recording, position >= Double(recording.upperBound + 1) { self.recording = nil }
    }

    private mutating func fire(_ step: Int, at offset: Int, events: inout [Event], reports: inout [Report]) {
        let isBeat = step % Self.stepsPerBeat == 0
        let isBarStart = step % Self.stepsPerBar == 0
        guard step >= 0 else {
            // The count-in always clicks
            guard isBeat else { return }
            events.append(Event(sound: isBarStart ? .accent : .click, offset: offset))
            reports.append(.beat(bar: 0, beat: (step + Self.stepsPerBar) / Self.stepsPerBeat + 1, phase: .countIn))
            return
        }
        let loopStep = step % loopSteps
        if isBeat {
            if isMetronomeOn { events.append(Event(sound: isBarStart ? .accent : .click, offset: offset)) }
            let phase: Phase = recording?.contains(step) == true ? .recording : .playing
            reports.append(.beat(bar: loopStep / Self.stepsPerBar + 1,
                                 beat: loopStep % Self.stepsPerBar / Self.stepsPerBeat + 1, phase: phase))
        }
        for pad in Self.pads where pattern.contains(DrumNote(pad: pad, step: loopStep)) {
            if let live = heardLive.firstIndex(where: { $0.pad == pad && $0.step == step }) {
                heardLive.remove(at: live)
                continue
            }
            events.append(Event(sound: pad.sound, offset: offset))
            reports.append(.played(pad))
        }
        heardLive.removeAll { $0.step < step }
    }
}
