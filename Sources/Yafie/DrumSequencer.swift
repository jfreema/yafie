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

/// A hit in the loop: which drum, and when, in ticks from the loop's start
struct DrumNote: Hashable, Sendable {
    var pad: DrumPad
    var tick: Int
}

/// How the loop's hits snap to the beat: to the nearest quarter, eighth or sixteenth note, or not at all. It can change
/// any time, since the loop keeps each hit where it was played.
enum DrumQuantize: String, CaseIterable, Sendable {
    case none, quarter = "1/4", eighth = "1/8", sixteenth = "1/16"

    /// The grid, in ticks. Nil leaves hits where they were played, to the nearest tick.
    var ticks: Int? {
        switch self {
        case .none: nil
        case .quarter: DrumSequencer.ticksPerBeat
        case .eighth: DrumSequencer.ticksPerBeat / 2
        case .sixteenth: DrumSequencer.ticksPerBeat / 4
        }
    }

    var name: String { self == .none ? "None" : rawValue }
}

/// The drum machine's clock: the metronome, and a loop of a bar or four, counted in ticks, 96 to a beat, as MIDI
/// sequencers count. That's fine enough to keep a hit where it was played. Pure, so it's tested. The player's audio
/// thread moves it on a buffer at a time.
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

    static let ticksPerBeat = 96
    static let beatsPerBar = 4
    static let ticksPerBar = beatsPerBar * ticksPerBeat
    static let tempos: ClosedRange<Double> = 40...240
    /// Hits on one drum closer together than this, in ticks, are one hit played twice, like the last pass's first beat
    /// played again as the next pass starts
    static let sameHit = ticksPerBeat / 16
    private static let pads = DrumPad.allCases

    let sampleRate: Double
    /// Beats a minute
    var tempo: Double = 120 {
        didSet {
            tempo = min(max(tempo, Self.tempos.lowerBound), Self.tempos.upperBound)
            // The clock keeps its place
            origin += Double(frames * Self.ticksPerBeat) * oldValue / (sampleRate * 60)
            frames = 0
        }
    }
    var isMetronomeOn = true
    /// Hits played live make no sound, for an output that plays them too late to play along to, like Bluetooth
    /// headphones. They still join the loop while recording.
    var areTapsMuted = false
    var quantize = DrumQuantize.sixteenth {
        didSet { snapAll() }
    }
    /// 1 or 4
    private(set) var bars = 1
    /// The loop's hits as they were played, to the nearest tick
    private(set) var pattern: Set<DrumNote> = []
    /// The same hits as they sound, snapped to the quantize grid
    private var sounding: Set<DrumNote> = []
    private(set) var isPlaying = false
    /// Where the clock was, in ticks, when it started or last changed tempo, and the frames since. Counting whole
    /// frames keeps it exact, where adding up each buffer's share of a tick would drift.
    private var origin: Double = 0
    private var frames = 0
    /// The next tick to sound
    private var next = 0
    /// One pass round the loop, being recorded
    private var recording: Range<Int>?
    /// Hits just played live and recorded at a tick still to come, so the loop doesn't play them a second time
    private var heardLive: [(pad: DrumPad, tick: Int)] = []

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        // So the audio thread doesn't allocate, even with a hit on every tick
        pattern.reserveCapacity(4 * Self.ticksPerBar * Self.pads.count)
        sounding.reserveCapacity(4 * Self.ticksPerBar * Self.pads.count)
        heardLive.reserveCapacity(32)
    }

    var loopTicks: Int { bars * Self.ticksPerBar }
    var framesPerTick: Double { sampleRate * 60 / tempo / Double(Self.ticksPerBeat) }
    var isRecording: Bool { recording != nil }
    /// Ticks since the loop first started, below zero during the count-in
    var position: Double { origin + Double(frames) / framesPerTick }

    /// From the loop's start
    mutating func play() {
        guard !isPlaying else { return }
        start(at: 0)
    }

    private mutating func start(at tick: Int) {
        isPlaying = true
        origin = Double(tick)
        frames = 0
        next = tick
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
            recording = start..<(start + loopTicks)
        } else {
            start(at: -Self.ticksPerBar)
            recording = 0..<loopTicks
        }
    }

    mutating func clear() {
        pattern.removeAll(keepingCapacity: true)
        sounding.removeAll(keepingCapacity: true)
        heardLive.removeAll(keepingCapacity: true)
    }

    /// One bar or four. Going to four repeats the bar, and going to one keeps the first.
    mutating func setBars(_ newBars: Int) {
        guard newBars != bars, newBars == 1 || newBars == 4 else { return }
        pattern = Self.resized(pattern, from: bars, to: newBars)
        bars = newBars
        recording = nil
        snapAll()
    }

    static func resized(_ pattern: Set<DrumNote>, from old: Int, to new: Int) -> Set<DrumNote> {
        let ticks = new * ticksPerBar
        guard new > old else { return pattern.filter { $0.tick < ticks } }
        return Set(pattern.flatMap { note in
            stride(from: note.tick, to: ticks, by: old * ticksPerBar).map { DrumNote(pad: note.pad, tick: $0) }
        })
    }

    /// The loop as it was, when the player starts over
    mutating func load(_ notes: Set<DrumNote>) {
        pattern = notes.filter { (0..<loopTicks).contains($0.tick) }
        snapAll()
    }

    /// Where a hit sounds: on the quantize grid's nearest line, in the loop
    func snapped(_ note: DrumNote) -> DrumNote {
        DrumNote(pad: note.pad, tick: wrapped(snapped(note.tick)))
    }

    private func snapped(_ tick: Int) -> Int {
        guard let grid = quantize.ticks else { return tick }
        return Int((Double(tick) / Double(grid)).rounded()) * grid
    }

    private func wrapped(_ tick: Int) -> Int { (tick % loopTicks + loopTicks) % loopTicks }

    private mutating func snapAll() {
        sounding.removeAll(keepingCapacity: true)
        for note in pattern { sounding.insert(snapped(note)) }
    }

    /// A hit played live sounds right away, unless taps are muted. While recording, the loop keeps it where it was
    /// played, and it sounds on the quantize grid.
    /// - Parameter latency: frames between making a sound and hearing it
    mutating func hit(_ pad: DrumPad, latency: Double, events: inout [Event], reports: inout [Report]) {
        if !areTapsMuted { events.append(Event(sound: pad.sound, offset: 0)) }
        guard isPlaying, let recording else { return }
        // Where the clock was when the player heard what they played along to
        let played = Int((position - latency / framesPerTick).rounded())
        // A little early for the pass's first beat, or a little late for the next pass's, still counts
        let grace = Self.ticksPerBeat / 8
        guard played >= recording.lowerBound - grace, played < recording.upperBound + grace else { return }
        let note = DrumNote(pad: pad, tick: wrapped(played))
        guard !pattern.contains(where: { $0.pad == pad && loopDistance($0.tick, note.tick) < Self.sameHit })
        else { return }
        pattern.insert(note)
        sounding.insert(snapped(note))
        reports.append(.recorded(note))
        // Snapped forward to a tick still to come, it would sound again a moment later. Muted, it sounds only then.
        let sounds = snapped(played)
        if !areTapsMuted, sounds >= next, heardLive.count < heardLive.capacity { heardLive.append((pad, sounds)) }
    }

    /// Ticks between two places in the loop, the shorter way round
    private func loopDistance(_ a: Int, _ b: Int) -> Int {
        let distance = abs(a - b) % loopTicks
        return min(distance, loopTicks - distance)
    }

    /// Moves the clock on by `count` frames, adding the clicks and the loop's hits that start in them
    mutating func advance(_ count: Int, events: inout [Event], reports: inout [Report]) {
        guard isPlaying, count > 0 else { return }
        let perTick = framesPerTick
        let end = frames + count
        // Each tick falls on a whole frame, in whichever buffer that's in
        while case let at = Int(((Double(next) - origin) * perTick).rounded(.up)), at < end {
            fire(next, at: max(0, at - frames), events: &events, reports: &reports)
            next += 1
        }
        frames = end
        // A sixteenth's grace, for a late hit on the next pass's first beat
        if let recording, position >= Double(recording.upperBound + Self.ticksPerBeat / 4) { self.recording = nil }
    }

    private mutating func fire(_ tick: Int, at offset: Int, events: inout [Event], reports: inout [Report]) {
        let isBeat = tick % Self.ticksPerBeat == 0
        let isBarStart = tick % Self.ticksPerBar == 0
        guard tick >= 0 else {
            // The count-in always clicks
            guard isBeat else { return }
            events.append(Event(sound: isBarStart ? .accent : .click, offset: offset))
            reports.append(.beat(bar: 0, beat: (tick + Self.ticksPerBar) / Self.ticksPerBeat + 1, phase: .countIn))
            return
        }
        let loopTick = tick % loopTicks
        if isBeat {
            if isMetronomeOn { events.append(Event(sound: isBarStart ? .accent : .click, offset: offset)) }
            let phase: Phase = recording?.contains(tick) == true ? .recording : .playing
            reports.append(.beat(bar: loopTick / Self.ticksPerBar + 1,
                                 beat: loopTick % Self.ticksPerBar / Self.ticksPerBeat + 1, phase: phase))
        }
        for pad in Self.pads where sounding.contains(DrumNote(pad: pad, tick: loopTick)) {
            if let live = heardLive.firstIndex(where: { $0.pad == pad && $0.tick == tick }) {
                heardLive.remove(at: live)
                continue
            }
            events.append(Event(sound: pad.sound, offset: offset))
            reports.append(.played(pad))
        }
        if !heardLive.isEmpty { heardLive.removeAll { $0.tick < tick } }
    }
}
