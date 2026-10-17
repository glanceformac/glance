import AppKit
import QuartzCore

// MARK: wip/cinema-h  Debug-only measurement and snapshots for the Cinema intro / outro.
// Commands (debug channel, `--debug` only):
//   fps:intro | fps:outro         play on the pill and record display-link frames + main-thread gaps
//   fps-tb:intro | fps-tb:outro   the same on a Touch Bar strip view hosted in a small test window
//   fps-tb:intro:noprobe          play it there without recording (CPU measurements)
//   tb-frame:intro:<t> | tb-frame:outro:<t>   offscreen Touch Bar frame at time t -> tb-<kind>-<t>.png
// Reports land in DebugChannel.snapshotDir as fps-<name>.txt. No screen capture: frames are read
// from the app's own display link and presentation layers.
@MainActor
enum CinemaProbe {
    static func run(_ cmd: String) -> Bool {
        let bits = cmd.split(separator: ":").map(String.init)
        guard let head = bits.first else { return false }
        switch head {
        case "fps":
            let outro = bits.count > 1 && bits[1] == "outro"
            pillFPS(outro: outro)
            return true
        case "fps-tb":
            let outro = bits.count > 1 && bits[1] == "outro"
            stripFPS(outro: outro, probe: !(bits.count > 2 && bits[2] == "noprobe"))
            return true
        case "tb-frame":
            guard bits.count == 3, let t = Double(bits[2]) else { return true }
            stripFrame(outro: bits[1] == "outro", t: t)
            return true
        case "context":
            // context:<normal|cinema|meeting|prompter|auto>  (isolated test instances only)
            guard Env.isolated, bits.count > 1 else { return true }
            AppSettings.shared.prefs.contextOverride = bits[1]
            IslandContext.shared.reevaluate()
            return true
        case "shot":
            // shot:<open|close|page=<name>>:<ms>:<name>  -> do the action, take ONE snapshot after ms
            // (one per run, so the snapshot's own cost never delays the animation it measures).
            guard bits.count >= 4, let ms = Double(bits[2]) else { return true }
            let m = IslandModel.shared
            let act = bits[1]
            if act == "open" { m.pinned = true; m.setExpanded(true) }
            else if act == "close" { m.pinned = false; m.setExpanded(false) }
            else if act.hasPrefix("page=") { DebugChannel.run("page:" + act.dropFirst(5)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) { DebugChannel.snapshot(name: bits[3]) }
            return true
        case "git-sim":
            // git-sim:<github|local|claude>:<push|commit>:<repo>:<commits>  (isolated only)
            guard Env.isolated, bits.count >= 5 else { return true }
            let src: GitCelebrations.Source = bits[1] == "github" ? .github : bits[1] == "claude" ? .claude : .local
            if bits[2] == "push" {
                GitCelebrations.shared.push(repo: bits[3], detail: bits[1] == "github" ? "on GitHub" : "", commits: Int(bits[4]) ?? 0, source: src)
            } else { GitCelebrations.shared.commit(repo: bits[3], message: "", source: src) }
            return true
        case "git-status":
            NSLog("Glance git status: %@ | pending %@", GitWatch.shared.status, GitCelebrations.shared.pendingSummary)
            return true
        default: return false
        }
    }

    // MARK: Pill

    private static func pillFPS(outro: Bool) {
        let m = IslandModel.shared
        m.debugFixedTime = nil
        guard let panel = NSApp.windows.first(where: { $0 is IslandPanel }), let content = panel.contentView else { return }
        m.celebrate(outro ? .cinemaOutro : .cinemaIntro)
        let dur = outro ? IntroH.outroDuration : IntroH.duration
        // Let SwiftUI insert the intro view, then find its layers.
        DispatchQueue.main.async {
            let host = findIntroLayer(in: content)
            let probe = FrameProbe(name: outro ? "pill-outro" : "pill-intro", duration: dur, sampled: host)
            probe.start(on: content)
        }
    }

    private static func findIntroLayer(in v: NSView) -> CALayer? {
        if v is CinemaIntroCA.IntroView { return v.layer }
        for s in v.subviews { if let l = findIntroLayer(in: s) { return l } }
        return nil
    }

    // MARK: Touch Bar strip (test window, never the real Touch Bar)

    private static var stripWindow: NSWindow?

    private static func makeStripWindow(visible: Bool) -> (NSWindow, GlowStripView) {
        stripWindow?.orderOut(nil); stripWindow = nil
        let size = NSSize(width: 1004, height: 30)
        let f = SafeScreen.primary.frame
        // Visible probes sit at the bottom-left of the screen (never at the top centre);
        // snapshots use a window far off-screen.
        let origin = visible ? NSPoint(x: f.minX + 10, y: f.minY + 10) : NSPoint(x: -30000, y: -30000)
        let w = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.ignoresMouseEvents = true
        let v = GlowStripView(frame: NSRect(origin: .zero, size: size))
        w.contentView = v
        w.orderFrontRegardless()
        v.layoutSubtreeIfNeeded(); v.layout()
        stripWindow = w
        return (w, v)
    }

    private static func stripFPS(outro: Bool, probe measure: Bool) {
        let (w, v) = makeStripWindow(visible: true)
        if outro { v.playOutro() } else { v.playIntro() }
        let dur = outro ? IntroH.outroDuration : IntroH.duration
        guard measure else {   // play only (for CPU measurements without the probe's own cost)
            DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.2) { w.orderOut(nil); if stripWindow === w { stripWindow = nil } }
            return
        }
        let probe = FrameProbe(name: outro ? "tb-outro" : "tb-intro", duration: dur, sampled: v.layer)
        probe.onDone = { w.orderOut(nil); if stripWindow === w { stripWindow = nil } }
        probe.start(on: v)
    }

    private static func stripFrame(outro: Bool, t: Double) {
        let (w, v) = makeStripWindow(visible: false)
        guard let root = v.layer else { return }
        let t0 = root.convertTime(CACurrentMediaTime(), from: nil)
        if outro { v.playOutro() } else { v.playIntro() }
        // Commit the animations first (they get their begin times), then freeze the whole strip.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            root.speed = 0
            root.timeOffset = t0 + t
            root.beginTime = 0
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let scale: CGFloat = 2
                let size = v.bounds.size
                if let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.scaleBy(x: scale, y: scale)
                    (root.presentation() ?? root).render(in: ctx)
                    if let img = ctx.makeImage() {
                        let dir = DebugChannel.snapshotDir
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                            .write(to: dir.appendingPathComponent("tb-\(outro ? "outro" : "intro")-\(String(format: "%.2f", t)).png"))
                    }
                }
                if ProcessInfo.processInfo.environment["GLANCE_PROBE_DUMP"] == "1" { dump(root) }
                w.orderOut(nil); if stripWindow === w { stripWindow = nil }
            }
        }
    }

    private static func dump(_ root: CALayer) {
        var lines: [String] = []
        func walk(_ l: CALayer, _ d: Int) {
            guard lines.count < 60 else { return }
            let p = l.presentation() ?? l
            lines.append(String(repeating: "  ", count: d) + "\(type(of: l)) frame=\(p.frame) op=\(p.opacity) hidden=\(p.isHidden) contents=\(l.contents != nil) anims=\(l.animationKeys() ?? []) speed=\(l.speed) off=\(l.timeOffset) begin=\(l.beginTime)")
            for s in l.sublayers ?? [] where d < 3 { walk(s, d + 1) }
        }
        walk(root, 0)
        NSLog("Glance probe dump:\n%@", lines.joined(separator: "\n"))
    }
}

/// Records every display-link callback while an animation plays, a 1/120 s main-thread timer
/// (gaps over 20 ms = the main thread was blocked), and whether the sampled presentation
/// layers changed between frames (Core Animation actually advancing).
@MainActor
final class FrameProbe: NSObject {
    private static var live: [FrameProbe] = []
    let name: String, duration: Double
    private weak var sampled: CALayer?
    private var link: CADisplayLink?
    private var timer: Timer?
    private var start: CFTimeInterval = 0
    private var ticks: [(t: CFTimeInterval, ts: CFTimeInterval, sig: Double)] = []
    private var lastTimer: CFTimeInterval = 0
    private var timerGaps: [(at: Double, ms: Double)] = []
    var onDone: (() -> Void)?

    init(name: String, duration: Double, sampled: CALayer?) {
        self.name = name; self.duration = duration; self.sampled = sampled
    }

    func start(on view: NSView) {
        Self.live.append(self)
        start = CACurrentMediaTime()
        lastTimer = start
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                let gap = now - self.lastTimer
                if gap > 0.020 { self.timerGaps.append((now - self.start, gap * 1000)) }
                self.lastTimer = now
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.2) { [weak self] in self?.finish() }
    }

    @objc private func tick(_ l: CADisplayLink) {
        ticks.append((CACurrentMediaTime() - start, l.timestamp, signature()))
    }

    /// Sum of presentation positions / opacities / bounds of the sampled tree (first 400 layers).
    private func signature() -> Double {
        guard let root = sampled?.presentation() else { return 0 }
        var sum = 0.0, n = 0
        func walk(_ l: CALayer) {
            guard n < 400 else { return }
            n += 1
            sum += Double(l.position.x) * 1.0001 + Double(l.position.y) * 0.37 + Double(l.opacity) * 1000 + Double(l.bounds.width) * 0.013
            for s in l.sublayers ?? [] { walk(s) }
        }
        walk(root)
        return sum
    }

    private func finish() {
        link?.invalidate(); link = nil
        timer?.invalidate(); timer = nil
        defer { Self.live.removeAll { $0 === self }; onDone?() }
        let active = ticks.filter { $0.t >= 0.05 && $0.t <= duration }
        let iv = zip(active.dropFirst(), active).map { ($0.ts - $1.ts) * 1000 }
        let late = iv.enumerated().filter { $0.element > 20 }
        let unchanged = zip(active.dropFirst(), active).filter { abs($0.0.sig - $0.1.sig) < 1e-9 }.map { $0.0.t }
        let span = (active.last?.ts ?? 0) - (active.first?.ts ?? 0)
        let fps = span > 0 ? Double(max(0, active.count - 1)) / span : 0
        let sorted = iv.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        var out = "probe \(name)  duration \(String(format: "%.2f", duration)) s\n"
        out += "display-link frames: \(active.count) over \(String(format: "%.3f", span)) s = \(String(format: "%.1f", fps)) fps\n"
        out += "frame interval ms: median \(String(format: "%.2f", pct(0.5)))  p95 \(String(format: "%.2f", pct(0.95)))  max \(String(format: "%.2f", sorted.last ?? 0))\n"
        out += "intervals > 20 ms (missed vsync): \(late.count)" + (late.isEmpty ? "" : "  at " + late.prefix(12).map { String(format: "%.2fs(%.0fms)", active[$0.offset].t, $0.element) }.joined(separator: " ")) + "\n"
        out += "main-thread timer gaps > 20 ms: \(timerGaps.count)" + (timerGaps.isEmpty ? "" : "  " + timerGaps.prefix(12).map { String(format: "%.2fs(%.0fms)", $0.at, $0.ms) }.joined(separator: " ")) + "\n"
        out += "frames where the sampled layers did not change: \(unchanged.count)" + (unchanged.isEmpty ? "" : "  at " + unchanged.prefix(20).map { String(format: "%.2f", $0) }.joined(separator: " ")) + "\n"
        let dir = DebugChannel.snapshotDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? out.write(to: dir.appendingPathComponent("fps-\(name).txt"), atomically: true, encoding: .utf8)
        NSLog("Glance probe: %@", out)
    }
}
