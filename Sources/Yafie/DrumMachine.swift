import AppKit
import SwiftUI

/// The drum machine's floating window. Its sound plays only while it's open.
@MainActor
final class DrumMachineWindowController: NSObject, NSWindowDelegate {
    private static let frameName = "Drums"

    private let model = DrumMachineModel()
    private lazy var audio = DrumAudio(onStatus: { [weak self] status in self?.statusChanged(status) },
                                       onMessage: { [weak self] message in self?.model.received(message) })
    private lazy var panel = makePanel()
    private var keyMonitor: Any?

    override init() {
        super.init()
        model.send = { [weak self] command in self?.audio.send(command) }
    }

    func show() {
        // An accessory app's window can open behind others
        NSApp.activate()
        let opening = !panel.isVisible
        panel.makeKeyAndOrderFront(nil)
        guard opening else { return }
        audio.start()
        watchSpace()
    }

    func windowWillClose(_ notification: Notification) {
        audio.stop()
        model.closed()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func statusChanged(_ status: DrumAudio.Status) {
        model.status = status
        if status == .ready { model.playerStarted() }
    }

    /// Space plays and stops while the drum machine has the keyboard
    private func watchSpace() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isSpace = event.charactersIgnoringModifiers == " "
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            let played = MainActor.assumeIsolated {
                guard let self, isSpace, event.window === self.panel else { return false }
                self.model.togglePlay()
                return true
            }
            return played ? nil : event
        }
    }

    private func makePanel() -> NSPanel {
        let view = DrumMachineView(model: model, retry: { [weak self] in self?.audio.start() })
        let panel = UtilityPanel(contentRect: NSRect(origin: .zero, size: DrumMachineView.size),
                                 styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        panel.title = "Drum Machine"
        panel.contentView = NSHostingView(rootView: view)
        panel.isFloatingPanel = true
        // Panels hide when their app deactivates, which would make the drums vanish at the first click elsewhere
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        if !panel.setFrameUsingName(Self.frameName) { panel.center() }
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }
}

// MARK: Model

/// What the drum machine shows, and what it asks the player to do. The loop is kept here too, so a player that
/// starts over gets it back.
@Observable @MainActor
final class DrumMachineModel {
    struct Beat: Equatable {
        /// From 1. Bar 0 is the count-in.
        var bar: Int
        var beat: Int
        var phase: DrumSequencer.Phase
    }

    var status = DrumAudio.Status.starting
    private(set) var isPlaying = false
    /// What's sounding now. Nil while stopped.
    private(set) var beat: Beat?
    /// Pads hit in the last moment, lit up
    private(set) var lit: Set<DrumPad> = []
    private(set) var pattern: Set<DrumNote> = []

    /// Beats a minute, set with setTempo
    private(set) var tempo: Double
    var isMetronomeOn: Bool {
        didSet {
            defaults.set(isMetronomeOn, forKey: Keys.metronome)
            send(.metronome(isMetronomeOn))
        }
    }
    /// How the loop's hits snap to the beat. It can change any time, since the loop keeps them as played.
    var quantize: DrumQuantize {
        didSet {
            defaults.set(quantize.rawValue, forKey: Keys.quantize)
            send(.quantize(quantize))
        }
    }
    /// 1 or 4
    var bars: Int {
        didSet {
            guard bars != oldValue else { return }
            defaults.set(bars, forKey: Keys.bars)
            pattern = DrumSequencer.resized(pattern, from: oldValue, to: bars)
            send(.bars(bars))
        }
    }

    /// To the player
    @ObservationIgnored var send: (DrumCommand) -> Void = { _ in }
    @ObservationIgnored private let defaults: UserDefaults
    /// Counts each pad's flashes, so an early one doesn't put out a later one
    @ObservationIgnored private var flashes: [DrumPad: Int] = [:]

    private enum Keys {
        static let tempo = "drumTempo"
        static let metronome = "drumMetronome"
        static let quantize = "drumQuantize"
        static let bars = "drumBars"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tempo = defaults.object(forKey: Keys.tempo) as? Double ?? 100
        isMetronomeOn = defaults.object(forKey: Keys.metronome) as? Bool ?? true
        quantize = defaults.string(forKey: Keys.quantize).flatMap(DrumQuantize.init) ?? .sixteenth
        bars = defaults.integer(forKey: Keys.bars) == 4 ? 4 : 1
    }

    var phase: DrumSequencer.Phase? { beat?.phase }

    /// In whole beats a minute, from 40 to 240
    func setTempo(_ value: Double) {
        let tempo = min(max(value.rounded(), DrumSequencer.tempos.lowerBound), DrumSequencer.tempos.upperBound)
        guard tempo != self.tempo else { return }
        self.tempo = tempo
        defaults.set(tempo, forKey: Keys.tempo)
        send(.tempo(tempo))
    }

    func hit(_ pad: DrumPad) {
        flash(pad)
        send(.hit(pad))
    }

    func togglePlay() {
        if isPlaying {
            send(.stop)
            isPlaying = false
            beat = nil
        } else {
            send(.play)
            isPlaying = true
        }
    }

    /// Records one pass round the loop, after a bar's count-in when it's stopped
    func record() {
        send(.record)
        isPlaying = true
    }

    func clear() {
        send(.clear)
        pattern = []
    }

    func received(_ message: DrumMessage) {
        switch message {
        case let .beat(bar, beat, phase):
            if isPlaying { self.beat = Beat(bar: bar, beat: beat, phase: phase) }
        case .played(let pad):
            flash(pad)
        case .recorded(let note):
            pattern.insert(note)
        case .ready, .alive, .changed, .failed:
            break
        }
    }

    /// A new player knows nothing yet, so it's told everything. A count-in or a recording pass that was going is lost.
    func playerStarted() {
        send(.tempo(tempo))
        send(.metronome(isMetronomeOn))
        send(.bars(bars))
        send(.quantize(quantize))
        send(.load(pattern))
        if isPlaying { send(.play) }
    }

    /// The window closed, and the player with it. The loop stays for next time.
    func closed() {
        isPlaying = false
        beat = nil
        lit = []
        status = .starting
    }

    private func flash(_ pad: DrumPad) {
        lit.insert(pad)
        flashes[pad, default: 0] += 1
        let count = flashes[pad]
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            if flashes[pad] == count { lit.remove(pad) }
        }
    }
}

// MARK: Views

/// The pads over the controls. All its state is in the model: the Command Line Tools can't build SwiftUI's @State.
struct DrumMachineView: View {
    static let size = CGSize(width: 520, height: 500)

    let model: DrumMachineModel
    let retry: () -> Void

    var body: some View {
        Group {
            switch model.status {
            case .failed(let message):
                MessageView(symbol: "speaker.slash", title: "Couldn't play sound", detail: message,
                            button: "Try Again", action: retry)
            case .starting, .ready:
                VStack(spacing: 14) {
                    DrumPads(model: model)
                    Text("Tap the trackpad where the pads are, with the pointer over them, or click them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    DrumControls(model: model)
                }
            }
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// Snare and kick on top, a hi-hat on either side below, as on the trackpad
private struct DrumPads: View {
    let model: DrumMachineModel

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                DrumPadView(pad: .snare, model: model)
                DrumPadView(pad: .kick, model: model)
            }
            GridRow {
                DrumPadView(pad: .hiHat, model: model)
                DrumPadView(pad: .hiHat, model: model)
            }
        }
        .overlay { TrackpadCatcher { model.hit($0) } }
    }
}

private struct DrumPadView: View {
    let pad: DrumPad
    let model: DrumMachineModel

    var body: some View {
        let isLit = model.lit.contains(pad)
        RoundedRectangle(cornerRadius: 14)
            .fill(pad.color.opacity(isLit ? 0.9 : 0.2))
            .overlay {
                Text(pad.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isLit ? Color.white : Color.primary)
            }
            .animation(.easeOut(duration: 0.12), value: isLit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(pad.name)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.hit(pad) }
    }
}

private extension DrumPad {
    var color: Color {
        switch self {
        case .kick: .orange
        case .snare: .blue
        case .hiHat: .teal
        }
    }
}

private struct DrumControls: View {
    let model: DrumMachineModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button { model.togglePlay() } label: {
                    Label(model.isPlaying ? "Stop" : "Play", systemImage: model.isPlaying ? "stop.fill" : "play.fill")
                        .frame(minWidth: 56)
                }
                .help("Play or stop (Space)")
                Button { model.record() } label: {
                    Label { Text("Record") } icon: { Image(systemName: "record.circle").foregroundStyle(.red) }
                }
                    .disabled(model.phase == .countIn || model.phase == .recording)
                    .help("Record one pass round the loop, with a bar's count-in when stopped")
                Button("Clear") { model.clear() }
                    .disabled(model.pattern.isEmpty)
                    .help("Clear the loop")
                Spacer(minLength: 0)
                BeatLights(beat: model.beat, bars: model.bars)
            }
            .controlSize(.large)
            HStack(spacing: 16) {
                Picker("Loop", selection: Binding(get: { model.bars }, set: { model.bars = $0 })) {
                    Text("1 Bar").tag(1)
                    Text("4 Bars").tag(4)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Picker("Quantize", selection: Binding(get: { model.quantize }, set: { model.quantize = $0 })) {
                    ForEach(DrumQuantize.allCases, id: \.self) { quantize in
                        Text(quantize.name).tag(quantize)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Snap the loop's hits to the nearest quarter, eighth or sixteenth note, or play them as you did")
                Toggle("Metronome", isOn: Binding(get: { model.isMetronomeOn }, set: { model.isMetronomeOn = $0 }))
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Text("Tempo")
                Slider(value: Binding(get: { model.tempo }, set: { model.setTempo($0) }), in: DrumSequencer.tempos)
                Stepper(value: Binding(get: { model.tempo }, set: { model.setTempo($0) }), in: DrumSequencer.tempos) {
                    Text("\(Int(model.tempo)) BPM")
                        .monospacedDigit()
                        .frame(width: 68, alignment: .trailing)
                }
            }
        }
    }
}

/// The bar's four beats, the one sounding lit: orange in the count-in, red while recording
private struct BeatLights: View {
    let beat: DrumMachineModel.Beat?
    let bars: Int

    var body: some View {
        HStack(spacing: 7) {
            Text(caption)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            ForEach(1...DrumSequencer.beatsPerBar, id: \.self) { index in
                Circle()
                    .fill(index == beat?.beat ? color : Color.secondary.opacity(0.25))
                    .frame(width: 12, height: 12)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(beat.map { "\(caption), beat \($0.beat)" } ?? "Stopped")
    }

    private var caption: String {
        guard let beat else { return "" }
        let bar = bars > 1 ? "Bar \(beat.bar) of \(bars)" : ""
        switch beat.phase {
        case .countIn: return "Count-in"
        case .recording: return bars > 1 ? "Recording · \(bar)" : "Recording"
        case .playing: return bar
        }
    }

    private var color: Color {
        switch beat?.phase {
        case .countIn: .orange
        case .recording: .red
        default: .accentColor
        }
    }
}

/// Over the pads, catching the trackpad's touches and clicks
private struct TrackpadCatcher: NSViewRepresentable {
    let onPad: (DrumPad) -> Void

    func makeNSView(context: Context) -> TrackpadPads {
        let view = TrackpadPads()
        view.onPad = onPad
        return view
    }

    func updateNSView(_ view: TrackpadPads, context: Context) { view.onPad = onPad }
}

/// A finger landing on the trackpad plays the pad in that corner of it, and a click plays the pad clicked. Touches
/// only arrive while the drum machine has the keyboard and the pointer is over the pads.
final class TrackpadPads: NSView {
    var onPad: ((DrumPad) -> Void)?
    /// Fingers on the trackpad now
    private var touching = 0
    private var lastTouch: TimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        setAccessibilityElement(false)  // VoiceOver uses the pads underneath
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func touchesBegan(with event: NSEvent) {
        for touch in event.touches(matching: .began, in: self) {
            onPad?(DrumPad(at: touch.normalizedPosition))
        }
        counted(event)
    }

    override func touchesEnded(with event: NSEvent) { counted(event) }
    override func touchesCancelled(with event: NSEvent) { counted(event) }

    private func counted(_ event: NSEvent) {
        touching = event.touches(matching: .touching, in: self).count
        lastTouch = ProcessInfo.processInfo.systemUptime
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A mouse's click. A tap or press on the trackpad clicks too, which mustn't play the pad a second time.
    override func mouseDown(with event: NSEvent) {
        guard touching == 0, ProcessInfo.processInfo.systemUptime - lastTouch > 0.35,
              bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        onPad?(DrumPad(at: CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)))
    }
}
