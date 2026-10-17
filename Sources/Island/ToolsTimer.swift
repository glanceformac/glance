import AppKit
import SwiftUI
import AVFoundation
import Observation

// MARK: feat/productivity - Timer extras: quick presets, stopwatch, break reminders, generated focus sounds.
// Idle cost is zero: a countdown is one one-shot Timer; the stopwatch and the on-screen digits tick only while
// the tab is visible; the audio engine exists only while a sound is playing.

@Observable @MainActor
final class QuickTimer {
    static let shared = QuickTimer()
    private(set) var endDate: Date?
    private(set) var total: TimeInterval = 0
    private(set) var pausedRemaining: TimeInterval?
    @ObservationIgnored private var fire: Timer?

    var running: Bool { endDate != nil }
    var active: Bool { running || pausedRemaining != nil }

    func remaining(at now: Date = Date()) -> TimeInterval {
        if let p = pausedRemaining { return p }
        return max(0, (endDate ?? now).timeIntervalSince(now))
    }

    func start(minutes: Double) {
        let secs = max(1, minutes * 60)
        total = secs
        pausedRemaining = nil
        schedule(after: secs)
    }

    func pause() {
        guard running else { return }
        pausedRemaining = remaining()
        endDate = nil
        fire?.invalidate(); fire = nil
    }

    func resume() {
        guard let p = pausedRemaining else { return }
        pausedRemaining = nil
        schedule(after: p)
    }

    func cancel() {
        endDate = nil; pausedRemaining = nil; total = 0
        fire?.invalidate(); fire = nil
    }

    private func schedule(after secs: TimeInterval) {
        endDate = Date().addingTimeInterval(secs)
        fire?.invalidate()
        let t = Timer(fire: endDate!, interval: 0, repeats: false) { _ in MainActor.assumeIsolated { QuickTimer.shared.finish() } }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        fire = t
    }

    private func finish() {
        let mins = total / 60
        cancel()
        IslandModel.shared.flash(.timer, seconds: 3)
        if !Env.isolated, IslandContext.shared.soundsAllowed { NSSound(named: "Glass")?.play() }   // silent in test instances
        Feedback.haptic(.levelChange)
        let label = mins >= 1 ? "\(Int(mins.rounded())) min" : "Timer"
        IslandModel.shared.enqueue(Peek(symbol: "timer", title: "Timer done", subtitle: label, tint: Color(nsColor: Look.shared.accentNS), duration: 4, prominent: true))
    }
}

@Observable @MainActor
final class Stopwatch {
    static let shared = Stopwatch()
    private(set) var startedAt: Date?
    private(set) var accumulated: TimeInterval = 0
    private(set) var laps: [TimeInterval] = []
    var running: Bool { startedAt != nil }
    func elapsed(at now: Date = Date()) -> TimeInterval { accumulated + (startedAt.map { now.timeIntervalSince($0) } ?? 0) }
    func toggle() {
        if let s = startedAt { accumulated += Date().timeIntervalSince(s); startedAt = nil } else { startedAt = Date() }
    }
    func lap() { guard running else { return }; laps.insert(elapsed(), at: 0); if laps.count > 20 { laps.removeLast() } }
    func reset() { startedAt = nil; accumulated = 0; laps = [] }
}

/// Optional 20-20-20 style nudge. Off by default; one one-shot timer at a time.
@Observable @MainActor
final class BreakReminder {
    static let shared = BreakReminder()
    @ObservationIgnored private var timer: Timer?

    func apply(minutes: Int) {
        timer?.invalidate(); timer = nil
        guard minutes > 0 else { return }
        let t = Timer(timeInterval: TimeInterval(minutes * 60), repeats: false) { _ in MainActor.assumeIsolated { BreakReminder.shared.fired() } }
        t.tolerance = 15
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fired() {
        let mins = ToolsPrefs.shared.data.breakReminderMinutes
        guard mins > 0 else { return }
        // Quiet in meetings (Context engine): skip this nudge, try again next interval.
        if IslandContext.shared.current != .meeting { IslandModel.shared.enqueue(Peek(symbol: "figure.walk", title: "Time for a break", subtitle: "Stand up, look away from the screen", tint: .green, duration: 5, prominent: true)); Feedback.haptic(.levelChange) }
        apply(minutes: mins)
    }
}

// MARK: Focus sounds (white / pink / brown noise generated in real time; no audio files)

final class NoiseState {
    var seed: UInt32 = 0x9E3779B9
    var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
    var brown = 0.0
    @inline(__always) func white() -> Double {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        return Double(seed) / Double(UInt32.max) * 2 - 1
    }
}

@Observable @MainActor
final class FocusSounds {
    static let shared = FocusSounds()
    enum Kind: String, CaseIterable { case white, pink, brown
        var title: String { rawValue.capitalized + " noise" }
        var blurb: String { switch self { case .white: "Bright, like a fan"; case .pink: "Balanced, like steady rain"; case .brown: "Deep, like a waterfall" } }
    }
    private(set) var playing: Kind?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var node: AVAudioSourceNode?
    /// Testing: render silently (volume forced to zero) so a test never makes noise on your Mac.
    var muteForTesting = false

    func toggle(_ kind: Kind) { playing == kind ? stop() : start(kind) }

    func start(_ kind: Kind) {
        stop()
        let state = NoiseState()
        let engine = AVAudioEngine()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let node = AVAudioSourceNode(format: fmt) { _, _, frames, abl -> OSStatus in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            for f in 0..<Int(frames) {
                let w = state.white()
                var s: Double
                switch kind {
                case .white: s = w * 0.5
                case .pink:
                    // Paul Kellet's economy pink filter
                    state.b0 = 0.99886 * state.b0 + w * 0.0555179; state.b1 = 0.99332 * state.b1 + w * 0.0750759
                    state.b2 = 0.96900 * state.b2 + w * 0.1538520; state.b3 = 0.86650 * state.b3 + w * 0.3104856
                    state.b4 = 0.55000 * state.b4 + w * 0.5329522; state.b5 = -0.7616 * state.b5 - w * 0.0168980
                    s = (state.b0 + state.b1 + state.b2 + state.b3 + state.b4 + state.b5 + state.b6 + w * 0.5362) * 0.11
                    state.b6 = w * 0.115926
                case .brown:
                    state.brown = (state.brown + 0.02 * w) / 1.02
                    s = state.brown * 3.5
                }
                for b in bufs { b.mData?.assumingMemoryBound(to: Float.self)[f] = Float(max(-1, min(1, s))) }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = muteForTesting ? 0 : Float(ToolsPrefs.shared.data.noiseVolume)
        do { try engine.start() } catch {
            NSLog("Glance: focus sound failed to start: \(error.localizedDescription)")
            return
        }
        self.engine = engine
        self.node = node
        playing = kind
        ToolsPrefs.shared.data.noiseKind = kind.rawValue
    }

    func stop() {
        engine?.stop()
        if let n = node { engine?.detach(n) }
        engine = nil; node = nil; playing = nil
    }

    func setVolume(_ v: Double) {
        ToolsPrefs.shared.data.noiseVolume = v
        engine?.mainMixerNode.outputVolume = muteForTesting ? 0 : Float(v)
    }
}

// MARK: Low-cost display helpers (AppKit text + Core Animation ring; no per-frame SwiftUI work)

/// A text label refreshed by one Timer, only while `interval` is non-nil (i.e. while something is running).
struct TickingLabel: NSViewRepresentable {
    var interval: TimeInterval?
    var font: NSFont
    var color: NSColor
    var text: @MainActor (Date) -> String

    final class Coordinator { var timer: Timer?; var interval: TimeInterval? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.alignment = .center
        f.backgroundColor = .clear
        f.isBordered = false
        return f
    }
    func updateNSView(_ f: NSTextField, context: Context) {
        f.font = font
        f.textColor = color
        let t = text
        f.stringValue = MainActor.assumeIsolated { t(Date()) }
        let c = context.coordinator
        guard c.interval != interval || (interval != nil && c.timer == nil) else { return }
        c.timer?.invalidate(); c.timer = nil; c.interval = interval
        if let iv = interval {
            let timer = Timer(timeInterval: iv, repeats: true) { [weak f] _ in
                MainActor.assumeIsolated { f?.stringValue = t(Date()) }
            }
            timer.tolerance = iv * 0.1
            RunLoop.main.add(timer, forMode: .common)
            c.timer = timer
        }
    }
    static func dismantleNSView(_ f: NSTextField, coordinator: Coordinator) { coordinator.timer?.invalidate() }
}

/// Progress ring driven entirely by one Core Animation stroke animation (the render server interpolates).
struct CountdownRing: NSViewRepresentable {
    var from: Double
    var remaining: TimeInterval
    var running: Bool
    var color: NSColor
    var track: NSColor
    var key: String   // changes only when the timer is (re)started, paused or cancelled

    final class RingView: NSView {
        let trackLayer = CAShapeLayer(), arc = CAShapeLayer()
        var lastKey = ""
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for l in [trackLayer, arc] { l.fillColor = nil; l.lineWidth = 4; layer?.addSublayer(l) }
            arc.lineCap = .round
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            let r = bounds.insetBy(dx: 3, dy: 3)
            // Start at 12 o'clock, clockwise (layer coordinates are bottom-up).
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: r.width / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            for l in [trackLayer, arc] { l.frame = bounds; l.path = path }
        }
    }

    func makeNSView(context: Context) -> RingView { RingView(frame: .zero) }
    func updateNSView(_ v: RingView, context: Context) {
        v.trackLayer.strokeColor = track.cgColor
        v.arc.strokeColor = color.cgColor
        guard v.lastKey != key else { return }
        v.lastKey = key
        v.arc.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        v.arc.strokeEnd = from
        CATransaction.commit()
        if running, remaining > 0 {
            let a = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = from; a.toValue = 1; a.duration = remaining
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            v.arc.add(a, forKey: "countdown")
            CATransaction.begin(); CATransaction.setDisableActions(true)
            v.arc.strokeEnd = 1
            CATransaction.commit()
        }
    }
}

// MARK: View

struct TimerExtrasView: View {
    let theme: Theme
    private let qt = QuickTimer.shared
    private let sw = Stopwatch.shared
    private let sounds = FocusSounds.shared
    private let prefs = ToolsPrefs.shared
    @State private var custom = ""
    private let presets = [1, 2, 3, 5, 10, 25]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            card { countdown }.frame(maxWidth: .infinity)
            card { stopwatch }.frame(width: 160)
            card { soundsAndBreaks }.frame(width: 200)
        }
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().padding(10).frame(maxHeight: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.card)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.cardStroke, lineWidth: 0.5)))
    }

    private func heading(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .heavy)).foregroundStyle(theme.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func small(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(theme.primary)
                .frame(width: 28, height: 24).background(Capsule().fill(theme.card.opacity(1.6)))
        }.buttonStyle(PressScaleStyle())
    }

    // Countdown
    private var countdown: some View {
        let rem = qt.remaining()
        let from = qt.total > 0 ? 1 - rem / qt.total : 0
        return VStack(spacing: 8) {
            heading("COUNTDOWN")
            ZStack {
                CountdownRing(from: from, remaining: rem, running: qt.running, color: theme.accentNS, track: NSColor(theme.tertiary.opacity(0.5)),
                              key: "\(qt.endDate?.timeIntervalSince1970 ?? 0)-\(qt.running)-\(qt.active)-\(qt.total)")
                TickingLabel(interval: qt.running ? 1 : nil, font: .monospacedDigitSystemFont(ofSize: 19, weight: .light), color: NSColor(theme.primary)) { _ in
                    QuickTimer.shared.active ? TimerExtrasView.clock(QuickTimer.shared.remaining()) : "--:--"
                }
                .frame(width: 80)
            }
            .frame(width: 84, height: 84)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 6), spacing: 5) {
                ForEach(presets, id: \.self) { m in
                    Button { qt.start(minutes: Double(m)) } label: {
                        Text("\(m)").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.primary)
                            .frame(maxWidth: .infinity).frame(height: 24).background(Capsule().fill(theme.card.opacity(1.6)))
                    }.buttonStyle(PressScaleStyle()).help("\(m) minute\(m == 1 ? "" : "s")")
                }
            }
            HStack(spacing: 5) {
                TextField("min", text: $custom).textFieldStyle(.plain).font(.system(size: 11)).multilineTextAlignment(.center)
                    .foregroundStyle(theme.primary).frame(width: 40, height: 24)
                    .background(Capsule().fill(theme.card.opacity(1.6)))
                    .onSubmit { startCustom() }
                ToolPill(theme: theme, title: "Start", symbol: "play.fill", prominent: true) { startCustom() }
                if qt.active {
                    small(qt.running ? "pause.fill" : "play.fill") { qt.running ? qt.pause() : qt.resume() }
                    small("xmark") { qt.cancel() }
                }
            }
            Text("Minutes. Rings the pill when done.").font(.system(size: 9)).foregroundStyle(theme.tertiary)
        }
    }

    private func startCustom() {
        let t = custom.replacingOccurrences(of: ",", with: ".")
        if let m = Double(t.trimmingCharacters(in: .whitespaces)), m > 0, m <= 600 { qt.start(minutes: m); custom = "" }
    }

    static func clock(_ s: TimeInterval) -> String {
        let t = Int(s.rounded(.up))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }

    // Stopwatch
    private var stopwatch: some View {
        VStack(spacing: 8) {
            heading("STOPWATCH")
            // 1 Hz while running keeps the island at about 0.4% CPU (a 10 Hz readout cost ~4%); tenths show when stopped and in laps.
            TickingLabel(interval: sw.running ? 1 : nil, font: .monospacedDigitSystemFont(ofSize: 24, weight: .light), color: NSColor(theme.primary)) { _ in
                let sw = Stopwatch.shared
                return sw.running ? TimerExtrasView.stop(sw.elapsed(), tenths: false) : TimerExtrasView.stop(sw.elapsed())
            }
            .frame(height: 30)
            HStack(spacing: 6) {
                ToolPill(theme: theme, title: sw.running ? "Stop" : "Start", symbol: sw.running ? "pause.fill" : "play.fill", prominent: true) { sw.toggle() }
                ToolPill(theme: theme, title: sw.running ? "Lap" : "Reset") { sw.running ? sw.lap() : sw.reset() }
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(sw.laps.enumerated()), id: \.offset) { i, l in
                        HStack {
                            Text("Lap \(sw.laps.count - i)").font(.system(size: 10)).foregroundStyle(theme.secondary)
                            Spacer()
                            Text(Self.stop(l)).font(.system(size: 10).monospacedDigit()).foregroundStyle(theme.primary)
                        }
                    }
                }
            }
        }
    }

    static func stop(_ e: TimeInterval, tenths: Bool = true) -> String {
        let t = Int(e * 10)
        return tenths ? String(format: "%02d:%02d.%d", t / 600, (t / 10) % 60, t % 10) : String(format: "%02d:%02d", t / 600, (t / 10) % 60)
    }

    private func chip(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(selected ? theme.primary : theme.secondary)
                .frame(maxWidth: .infinity).frame(height: 24)
                .background(Capsule().fill(selected ? theme.accent.opacity(theme.dark ? 0.3 : 0.2) : theme.card.opacity(1.4)))
                .overlay(Capsule().strokeBorder(selected ? theme.accent.opacity(0.55) : .clear, lineWidth: 0.8))
        }.buttonStyle(PressScaleStyle())
    }

    // Focus sounds + break reminders
    private var soundsAndBreaks: some View {
        VStack(alignment: .leading, spacing: 7) {
            heading("FOCUS SOUNDS")
            HStack(spacing: 5) {
                ForEach(FocusSounds.Kind.allCases, id: \.self) { k in
                    chip(k.rawValue.capitalized, selected: sounds.playing == k) { sounds.toggle(k) }.help(k.blurb)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").font(.system(size: 9)).foregroundStyle(theme.secondary)
                Slider(value: Binding(get: { prefs.data.noiseVolume }, set: { sounds.setVolume($0) }), in: 0.05...1).controlSize(.mini)
            }
            Text(sounds.playing.map { "\($0.title) playing. Generated on this Mac." } ?? "Soft generated noise. Nothing is downloaded.")
                .font(.system(size: 9)).foregroundStyle(theme.tertiary).fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.3)
            heading("BREAK REMINDER")
            HStack(spacing: 4) {
                ForEach([0, 20, 30, 45, 60], id: \.self) { m in
                    chip(m == 0 ? "Off" : "\(m)", selected: prefs.data.breakReminderMinutes == m) {
                        prefs.data.breakReminderMinutes = m
                        BreakReminder.shared.apply(minutes: m)
                    }
                }
            }
            Text(prefs.data.breakReminderMinutes == 0 ? "Optional nudge, in minutes." : "A peek every \(prefs.data.breakReminderMinutes) min while Glance runs.")
                .font(.system(size: 9)).foregroundStyle(theme.tertiary)
        }
    }
}
