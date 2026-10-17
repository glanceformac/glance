import AppKit
import QuartzCore
import SwiftUI

/// Cinema intro "H" (the chosen design): an exact native port of `drawH()` from the browser preview
/// (cinema-previews/index.html), plus a matching outro.
///
/// How it stays identical AND smooth: the preview's own maths (same timeline, `ease` = cubic out,
/// `easeIO` = cubic in-out, same sizes in canvas pixels) is evaluated once, 60 times per second
/// of the timeline, into keyframe arrays (cached per size). Core Animation then plays those
/// keyframes in the render server: one animation group per layer, only position / opacity /
/// scale change, nothing is redrawn, and the app does no work while it plays.
///
/// Canvas space: the preview pill is 880 x 128 px. A target of W x H points uses k = H / 128 for
/// sizes and a canvas width of W / k (so the Touch Bar gets a wide canvas with the same feel).
enum IntroH {
    static let introTotal = 5.9
    static var duration: Double { introTotal }
    static let outroTotal = 1.5
    static var outroDuration: Double { outroTotal }
    static let fps = 60.0
    static let rate = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)

    static let stripColours = ["#ff2d6f", "#ff6a3d", "#ffb02e", "#a855f7", "#22d3ee", "#e11d48", "#f97316"]

    static func hex(_ s: String) -> NSColor {
        var v: UInt64 = 0
        Scanner(string: String(s.dropFirst())).scanHexInt64(&v)
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    // MARK: The preview's helpers, verbatim

    static func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { max(a, min(b, x)) }
    static func ease(_ t: Double) -> Double { 1 - pow(1 - clamp(t), 3) }
    static func easeIO(_ t0: Double) -> Double { let t = clamp(t0); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }

    /// Deterministic random numbers (the same LCG is used by the reference page for comparisons).
    struct RNG {
        var s: UInt64
        mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / 9007199254740992 }
    }

    struct Strip { let x, w, d, h: Double; let c: String }
    struct Dust { let x, y, r, s: Double }

    /// STRIPS and DUST exactly as the preview defines them (positions in canvas px).
    static func strips(_ n: Int, W: Double) -> [Strip] {
        var r = RNG(s: 0x5eed)
        return (0..<n).map { i in
            let x = r.next() * W, w = 2 + r.next() * 3, d = r.next() * 0.35, h = 0.5 + r.next() * 0.5
            return Strip(x: x, w: w, d: d, h: h, c: stripColours[i % 7])
        }
    }
    static func dust(_ n: Int) -> [Dust] {
        var r = RNG(s: 0xd057)
        return (0..<n).map { _ in Dust(x: r.next(), y: r.next(), r: 0.6 + r.next() * 1.4, s: 0.2 + r.next() * 0.8) }
    }

    // MARK: Sampled keyframes

    final class Track {
        let path: String
        var values: [Any] = []
        let discrete: Bool
        init(_ path: String, discrete: Bool = false) { self.path = path; self.discrete = discrete }
    }

    /// Everything the intro needs, sampled at 60 Hz from the preview's maths (canvas px units).
    struct Plan {
        var W: Double, H: Double
        var times: [NSNumber]
        var beamX: [Any], beamOn: [Any]
        var dust: [(d: Dust, y: [Any], a: [Any])]
        var textA: [Any], blurA: [[Any]]          // crossfade weights for blur 6 / 4 / 2 / 0 px
        var strips: [(s: Strip, x: [Any], a: [Any])]
        var lineA: [Any], pulseScale: [Any], pulseA: [Any]
        var edgeL: [Any], edgeR: [Any], edgeA: [Any]
    }

    @MainActor static var cache: [String: Plan] = [:]

    @MainActor static func plan(W: Double, stripCount: Int, dustCount: Int) -> Plan {
        let key = "\(Int(W))-\(stripCount)-\(dustCount)"
        if let p = cache[key] { return p }
        let H = 128.0, cx = W / 2, n = Int(introTotal * fps)
        let times = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        let ts = (0...n).map { Double($0) / fps }
        let widen = W / 880                                   // beam sweep range follows the canvas width
        let ss = strips(stripCount, W: W), ds = dust(dustCount)
        var p = Plan(W: W, H: H, times: times, beamX: [], beamOn: [], dust: [], textA: [], blurA: blurLevels.map { _ in [] }, strips: [],
                     lineA: [], pulseScale: [], pulseA: [], edgeL: [], edgeR: [], edgeA: [])
        // 1) dust beam 0.2 to 1.8
        for t in ts {
            let sw = easeIO(seg(t, 0.2, 1.8))
            p.beamX.append(-120 * widen + sw * (W + 240 * widen))
            p.beamOn.append(Float(seg(t, 0.15, 0.45) * (1 - seg(t, 1.6, 1.9))))
        }
        for d in ds {
            var ys: [Any] = [], as_: [Any] = []
            for (i, t) in ts.enumerated() {
                let x = d.x * W, y = (d.y * H + t * 12 * d.s).truncatingRemainder(dividingBy: H)
                let bx = p.beamX[i] as! Double, on = Double(p.beamOn[i] as! Float)
                let dist = abs(x - bx)
                ys.append(y)
                as_.append(Float(dist < 160 * widen ? (1 - dist / (160 * widen)) * on * 0.9 : 0))
            }
            p.dust.append((d, ys, as_))
        }
        // 2) CINEMA MODE 2.0 to 3.7: alpha + blur (6 px to sharp), blur as weights of 4 pre-blurred copies
        for t in ts {
            let e = ease(seg(t, 2.0, 2.6))
            let tin = e * (1 - seg(t, 3.6, 4.0))
            p.textA.append(Float(tin))
            let b = (1 - e) * 6                                   // 6 ... 0 px
            let levels = blurLevels
            var w = Array(repeating: 0.0, count: levels.count)
            if b >= levels[0] { w[0] = 1 } else if b <= 0 { w[levels.count - 1] = 1 } else {
                for j in 0..<(levels.count - 1) where b <= levels[j] && b >= levels[j + 1] {
                    let f = (levels[j] - b) / (levels[j] - levels[j + 1])
                    w[j] = 1 - f; w[j + 1] = f
                    break
                }
            }
            for j in 0..<levels.count { p.blurA[j].append(Float(w[j])) }
        }
        // 3) ribbons race to the centre 3.6 to 4.7
        for s in ss {
            var xs: [Any] = [], as_: [Any] = []
            for t in ts {
                let intro = seg(t, 3.5, 3.8), fade = 1 - seg(t, 4.65, 4.8)
                let k = ease(seg(t, 3.7 + s.d * 0.8, 4.7))
                xs.append(s.x + (cx - s.x) * k)
                as_.append(Float(intro * fade * (0.35 + 0.65 * k)))
            }
            p.strips.append((s, xs, as_))
        }
        // 4) pulse 4.7 to 5.15 (line + radial share the alpha); 5) line opens 5.15 to 5.8
        for t in ts {
            let pl = seg(t, 4.7, 5.15)
            let on = pl > 0 && t < 5.9
            let a = on ? 1 - seg(t, 5.4, 5.9) : 0
            p.lineA.append(Float(a))
            let pulse = sin(clamp(pl) * .pi)
            p.pulseScale.append((150 * pulse + 10) / 160)
            p.pulseA.append(Float(a))
            let op = easeIO(seg(t, 5.15, 5.8))
            let half = op * W / 2
            p.edgeL.append(cx - half); p.edgeR.append(cx + half)
            p.edgeA.append(Float(op > 0 && op < 1 ? 0.85 : 0))
        }
        cache[key] = p
        return p
    }

    static func track(_ path: String, _ values: [Any], _ times: [NSNumber], duration: Double, discrete: Bool = false) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: path)
        a.values = values
        a.keyTimes = times
        a.duration = duration
        a.calculationMode = discrete ? .discrete : .linear
        return a
    }

    /// One group per layer, starting at local time ~0 of the timeline layer.
    static func group(_ anims: [CAAnimation], duration: Double) -> CAAnimationGroup {
        let g = CAAnimationGroup()
        g.animations = anims
        g.duration = duration
        g.beginTime = 0.0001          // 0 would mean "now"
        g.fillMode = .both
        g.isRemovedOnCompletion = false
        g.preferredFrameRateRange = rate
        return g
    }

    // MARK: Text: drawn once per blur level exactly like drawText() (bold 34 px, 10 px tracking,
    // warm glow, centred at W/2 + 5, H/2 + 2), then only opacity animates.

    @MainActor static var textCache: [String: [CGImage]] = [:]
    /// Blur levels (canvas px) for the soft-to-sharp text; neighbouring copies are crossfaded.
    static let blurLevels: [Double] = [6, 4.5, 3, 2, 1.25, 0.6, 0]

    /// `textScale` > 1 enlarges the lettering only (the Touch Bar is 30 pt tall, so the pill's
    /// proportions would give ~7 pt text there).
    @MainActor static func textImages(k: Double, W: Double, textScale: Double = 1) -> [CGImage] {
        let key = "\(k)-\(W)-\(textScale)"
        if let c = textCache[key] { return c }
        let scale = 2.0                                       // retina
        let pw = Int((W * k * scale).rounded()), ph = Int((128 * k * scale).rounded())
        var out: [CGImage] = []
        for blurPx in blurLevels {
            guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            let f = k * scale                                   // canvas px -> device px
            let ts = f * textScale                              // lettering only
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
            let font = NSFont.systemFont(ofSize: 34 * ts, weight: .bold)
            let attr = NSAttributedString(string: "CINEMA MODE", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: 10 * ts])
            let sz = attr.size()
            // Canvas letterSpacing adds space after every letter, so the visual centre sits 5 px left; the preview adds +5.
            let x = W / 2 * f + 5 * ts - sz.width / 2, y = Double(ph) - (64 + 2) * f - sz.height / 2
            ctx.setShadow(offset: .zero, blur: 20 * ts, color: NSColor(srgbRed: 1, green: 200 / 255, blue: 170 / 255, alpha: 0.8).cgColor)
            attr.draw(at: CGPoint(x: x, y: y))
            NSGraphicsContext.restoreGraphicsState()
            guard var img = ctx.makeImage() else { continue }
            if blurPx > 0, let blurred = blur(img, sigma: blurPx * ts) { img = blurred }
            out.append(img)
        }
        textCache[key] = out
        return out
    }

    static func blur(_ img: CGImage, sigma: Double) -> CGImage? {
        let ci = CIImage(cgImage: img).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(ci, from: ci.extent)
    }

    // MARK: Build the intro

    /// Builds the intro inside `root`. Returns the timeline layer: set its `beginTime` to start,
    /// or `speed = 0` + `timeOffset` to freeze a frame (snapshots).
    @MainActor
    static func build(in root: CALayer, size: CGSize, stripCount: Int, dustCount: Int, reduceMotion: Bool, textScale: Double = 1) -> CALayer {
        let k = Double(size.height) / 128, W = Double(size.width) / k
        let D = introTotal
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let timeline = CALayer()
        timeline.frame = CGRect(origin: .zero, size: size)
        timeline.masksToBounds = true
        timeline.isGeometryFlipped = true                      // canvas coordinates: y grows downwards
        root.addSublayer(timeline)
        func pt(_ v: Double) -> CGFloat { CGFloat(v * k) }
        func scaled(_ vs: [Any]) -> [Any] { vs.map { pt($0 as! Double) } }

        let bg = CALayer()
        bg.frame = timeline.bounds
        bg.backgroundColor = NSColor.black.cgColor
        timeline.addSublayer(bg)

        let imgs = textImages(k: k, W: W, textScale: textScale)
        if reduceMotion {
            let t = CALayer()
            t.frame = timeline.bounds; t.contents = imgs.last; t.contentsGravity = .resize; t.opacity = 0
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0, 0, 1, 1, 0].map { Float($0) }; a.keyTimes = [0, 0.08, 0.2, 0.78, 0.92]; a.duration = D
            t.add(group([a], duration: D), forKey: "g")
            timeline.addSublayer(t)
            return timeline
        }

        let p = plan(W: W, stripCount: stripCount, dustCount: dustCount)
        let times = p.times

        // 1) Beam: radial gradient, radius 170 px (wider canvases widen it too), cream -> soft amber -> clear.
        let beamR = 170 * (W / 880 > 1 ? W / 880 : 1)
        let beam = CAGradientLayer()
        beam.type = .radial
        beam.colors = [NSColor(srgbRed: 1, green: 238 / 255, blue: 210 / 255, alpha: 0.62).cgColor,
                       NSColor(srgbRed: 1, green: 200 / 255, blue: 150 / 255, alpha: 0.2).cgColor, NSColor.clear.cgColor]
        beam.locations = [0, 0.5, 1]
        beam.startPoint = CGPoint(x: 0.5, y: 0.5); beam.endPoint = CGPoint(x: 1, y: 1)
        beam.bounds = CGRect(x: 0, y: 0, width: pt(beamR * 2), height: pt(beamR * 2))
        beam.position = CGPoint(x: pt(-200), y: pt(64))
        beam.opacity = 0
        beam.add(group([track("position.x", scaled(p.beamX), times, duration: D), track("opacity", p.beamOn, times, duration: D)], duration: D), forKey: "g")
        timeline.addSublayer(beam)

        // Dust specks.
        for d in p.dust {
            let l = CALayer()
            let r = pt(d.d.r)
            l.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            l.cornerRadius = r
            l.backgroundColor = NSColor.white.cgColor
            l.position = CGPoint(x: pt(d.d.x * W), y: pt(d.d.y * 128))
            l.opacity = 0
            l.add(group([track("position.y", scaled(d.y), times, duration: D, discrete: true), track("opacity", d.a, times, duration: D)], duration: D), forKey: "g")
            timeline.addSublayer(l)
        }

        // 2) Text: one copy per blur level, blurriest at the bottom. Inside a group-opacity
        //    container (the text alpha), the lower copy of each neighbouring pair is fully opaque
        //    and the sharper copy fades in on top: a true mix of the two blur levels. (Splitting
        //    the alpha between both copies composited them "over" each other, so mid-way frames
        //    came out dimmer and softer than the reference, most visibly around 2.3 s.)
        let textBox = CALayer()
        textBox.frame = timeline.bounds
        textBox.allowsGroupOpacity = true
        textBox.opacity = 0
        textBox.add(group([track("opacity", p.textA, times, duration: D)], duration: D), forKey: "g")
        timeline.addSublayer(textBox)
        let nLev = imgs.count
        var over = Array(repeating: [Any](), count: nLev)
        for i in 0..<times.count {
            let w = (0..<nLev).map { Double(p.blurA[$0][i] as! Float) }
            let top = (0..<nLev).last(where: { w[$0] > 0.0005 }) ?? (nLev - 1)
            for j in 0..<nLev {
                let v: Double = j == top ? (top > 0 && w[top] < 0.9995 && w[top - 1] > 0.0005 ? w[top] : 1)
                              : (j == top - 1 && w[j] > 0.0005 ? 1 : 0)
                over[j].append(Float(v))
            }
        }
        for (j, img) in imgs.enumerated() {
            let l = CALayer()
            l.frame = textBox.bounds
            l.contents = img
            l.contentsGravity = .resize
            l.opacity = 0
            l.add(group([track("opacity", over[j], times, duration: D)], duration: D), forKey: "g")
            textBox.addSublayer(l)
        }

        // 3) Ribbons: full height with a soft fade over h of the height, 2-5 px wide.
        for s in p.strips {
            let l = CAGradientLayer()
            let c = hex(s.s.c)
            l.colors = [c.withAlphaComponent(0).cgColor, c.cgColor, c.withAlphaComponent(0).cgColor]
            l.startPoint = CGPoint(x: 0.5, y: 0); l.endPoint = CGPoint(x: 0.5, y: 1)
            l.bounds = CGRect(x: 0, y: 0, width: pt(s.s.w), height: pt(128 * s.s.h))
            l.position = CGPoint(x: pt(s.s.x), y: pt(64))
            l.opacity = 0
            l.add(group([track("position.x", scaled(s.x), times, duration: D), track("opacity", s.a, times, duration: D)], duration: D), forKey: "g")
            timeline.addSublayer(l)
        }

        // 4) Bright 3 px line + pink radial pulse (radius 150 * pulse + 10 px).
        let line = CALayer()
        line.backgroundColor = NSColor.white.cgColor
        line.bounds = CGRect(x: 0, y: 0, width: pt(3), height: pt(128))
        line.position = CGPoint(x: pt(W / 2), y: pt(64))
        line.opacity = 0
        line.add(group([track("opacity", p.lineA, times, duration: D)], duration: D), forKey: "g")
        timeline.addSublayer(line)

        let pulse = CAGradientLayer()
        pulse.type = .radial
        pulse.colors = [NSColor(srgbRed: 1, green: 120 / 255, blue: 160 / 255, alpha: 0.95).cgColor, NSColor(srgbRed: 1, green: 120 / 255, blue: 160 / 255, alpha: 0).cgColor]
        pulse.startPoint = CGPoint(x: 0.5, y: 0.5); pulse.endPoint = CGPoint(x: 1, y: 1)
        pulse.bounds = CGRect(x: 0, y: 0, width: pt(320), height: pt(320))
        pulse.position = CGPoint(x: pt(W / 2), y: pt(64))
        pulse.opacity = 0
        // Radius animates via bounds (the render server redraws the gradient; no transform involved).
        let sizes: [Any] = p.pulseScale.map { v -> Any in let d = pt(320) * CGFloat(v as! Double); return NSValue(size: NSSize(width: d, height: d)) }
        pulse.add(group([track("bounds.size", sizes, times, duration: D), track("opacity", p.pulseA, times, duration: D)], duration: D), forKey: "g")
        timeline.addSublayer(pulse)

        // 5) Two thin white edges (2 px, alpha .85) move apart.
        for xs in [p.edgeL, p.edgeR] {
            let e = CALayer()
            e.backgroundColor = NSColor(white: 1, alpha: 0.85).cgColor
            e.bounds = CGRect(x: 0, y: 0, width: pt(2), height: pt(128))
            e.position = CGPoint(x: pt(W / 2), y: pt(64))
            e.opacity = 0
            e.add(group([track("position.x", scaled(xs), times, duration: D), track("opacity", p.edgeA, times, duration: D)], duration: D), forKey: "g")
            timeline.addSublayer(e)
        }
        // Hand-over: the stage fades as the equaliser would fade in (5.3 to 5.9 in the preview).
        let bgA = (0...Int(D * fps)).map { i -> Any in Float(1 - ease(seg(Double(i) / fps, 5.3, 5.9))) }
        bg.add(group([track("opacity", bgA, times, duration: D)], duration: D), forKey: "g")
        return timeline
    }

    // MARK: Outro (~1.5 s): the reverse in miniature
    //  0-0.35   a soft line gathers at the centre (bars have settled)
    //  0.25-1.1 thin ribbons fly out from the centre and fade
    //  0.9-1.35 a last warm beam flicker; 1.2-1.5 fade to the normal pill

    @MainActor
    static func buildOutro(in root: CALayer, size: CGSize, stripCount: Int, reduceMotion: Bool) -> CALayer {
        let k = Double(size.height) / 128, W = Double(size.width) / k, cx = W / 2
        let T = outroTotal, n = Int(T * fps)
        let times = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        let ts = (0...n).map { Double($0) / fps }
        func pt(_ v: Double) -> CGFloat { CGFloat(v * k) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let timeline = CALayer()
        timeline.frame = CGRect(origin: .zero, size: size)
        timeline.masksToBounds = true
        timeline.isGeometryFlipped = true
        root.addSublayer(timeline)
        let bg = CALayer()
        bg.frame = timeline.bounds
        bg.backgroundColor = NSColor.black.cgColor
        bg.add(group([track("opacity", ts.map { Float(ease(seg($0, 0, 0.2)) * (1 - ease(seg($0, 1.2, 1.5)))) }, times, duration: T)], duration: T), forKey: "g")
        bg.opacity = 0
        timeline.addSublayer(bg)
        if reduceMotion { return timeline }

        let line = CALayer()
        line.backgroundColor = NSColor(white: 1, alpha: 0.9).cgColor
        line.bounds = CGRect(x: 0, y: 0, width: pt(3), height: pt(128))
        line.position = CGPoint(x: pt(cx), y: pt(64))
        line.opacity = 0
        line.add(group([track("opacity", ts.map { Float(ease(seg($0, 0.05, 0.3)) * (1 - seg($0, 0.45, 0.7))) }, times, duration: T),
                        track("transform.scale.y", ts.map { 0.2 + 0.8 * ease(seg($0, 0.05, 0.3)) }, times, duration: T)], duration: T), forKey: "g")
        timeline.addSublayer(line)

        for s in strips(stripCount, W: W) {
            let l = CAGradientLayer()
            let c = hex(s.c)
            l.colors = [c.withAlphaComponent(0).cgColor, c.cgColor, c.withAlphaComponent(0).cgColor]
            l.startPoint = CGPoint(x: 0.5, y: 0); l.endPoint = CGPoint(x: 0.5, y: 1)
            l.bounds = CGRect(x: 0, y: 0, width: pt(s.w), height: pt(128 * s.h))
            l.position = CGPoint(x: pt(cx), y: pt(64))
            l.opacity = 0
            let start = 0.3 + s.d * 0.5
            let xs: [Any] = ts.map { t in pt(cx + (s.x - cx) * ease(seg(t, start, 1.05))) }
            let a: [Any] = ts.map { t in Float(seg(t, start - 0.02, start) * (1 - ease(seg(t, start, 1.1)))) }
            l.add(group([track("position.x", xs, times, duration: T), track("opacity", a, times, duration: T)], duration: T), forKey: "g")
            timeline.addSublayer(l)
        }

        let beam = CAGradientLayer()
        beam.type = .radial
        beam.colors = [NSColor(srgbRed: 1, green: 238 / 255, blue: 210 / 255, alpha: 0.62).cgColor,
                       NSColor(srgbRed: 1, green: 200 / 255, blue: 150 / 255, alpha: 0.2).cgColor, NSColor.clear.cgColor]
        beam.locations = [0, 0.5, 1]
        beam.startPoint = CGPoint(x: 0.5, y: 0.5); beam.endPoint = CGPoint(x: 1, y: 1)
        let br = 170 * (W / 880 > 1 ? W / 880 : 1)
        beam.bounds = CGRect(x: 0, y: 0, width: pt(br * 2), height: pt(br * 2))
        beam.position = CGPoint(x: pt(cx), y: pt(64))
        beam.opacity = 0
        let flicker: [Any] = ts.map { t in
            let on = seg(t, 0.9, 1.0) * (1 - seg(t, 1.15, 1.35))
            return Float(on * (0.55 + 0.25 * sin(t * 60)))          // a projector's last flutter
        }
        beam.add(group([track("opacity", flicker, times, duration: T)], duration: T), forKey: "g")
        timeline.addSublayer(beam)
        return timeline
    }

    // MARK: Outer glow (Ambilight) during the intro, following the ribbons.
    //  Ring order: top, right, bottom, left (clockwise from the top), first repeated at the end.

    static func ring(_ top: CGColor, _ right: CGColor, _ bottom: CGColor, _ left: CGColor) -> [CGColor] { [top, right, bottom, left, top] }

    /// Colour keyframes sampled from where the ribbons are: each side shows the average colour of
    /// the ribbons on that side; as they reach the centre the colour gathers at the bottom.
    @MainActor static func glowColours() -> CAKeyframeAnimation {
        let p = plan(W: 880, stripCount: 40, dustCount: 60)
        let n = p.times.count
        let amber = SIMD3<Double>(1, 0.78, 0.5)
        var values: [Any] = []
        func rgb(_ s: String) -> SIMD3<Double> { let c = hex(s); return SIMD3(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)) }
        let cols = p.strips.map { rgb($0.s.c) }
        for i in 0..<n {
            let t = Double(i) / fps
            var left = SIMD3<Double>(0, 0, 0), right = left, centre = left
            var wl = 0.0, wr = 0.0, wc = 0.0
            for (j, s) in p.strips.enumerated() {
                let x = s.x[i] as! Double, a = Double(s.a[i] as! Float)
                let f = x / 880
                left += cols[j] * a * max(0, 1 - f * 1.6); wl += a * max(0, 1 - f * 1.6)
                right += cols[j] * a * max(0, f * 1.6 - 0.6); wr += a * max(0, f * 1.6 - 0.6)
                let cw = a * max(0, 1 - abs(f - 0.5) * 3); centre += cols[j] * cw; wc += cw
            }
            func norm(_ v: SIMD3<Double>, _ w: Double) -> SIMD3<Double> { w > 0.001 ? v / w : SIMD3(0, 0, 0) }
            var l = norm(left, wl), r = norm(right, wr), c = norm(centre, wc)
            // Pulse: the collapse flashes warm white at the centre.
            let pulse = sin(clamp(seg(t, 4.7, 5.15)) * .pi)
            c = c + (SIMD3(1, 0.85, 0.9) - c) * pulse * 0.7
            if t < 2.0 { l = amber; r = amber; c = amber }        // a very faint warm wash with the beam
            if t > 4.6 { l = l + (c - l) * seg(t, 4.6, 4.9); r = r + (c - r) * seg(t, 4.6, 4.9) }
            func cg(_ v: SIMD3<Double>) -> CGColor { NSColor(srgbRed: v.x, green: v.y, blue: v.z, alpha: 1).cgColor }
            values.append(ring(cg((l + r) / 2 * 0.6), cg(r), cg(c), cg(l)))
        }
        return track("colors", values, p.times, duration: introTotal)
    }

    static func glowOpacity() -> CAKeyframeAnimation {
        let n = Int(introTotal * fps)
        let times = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        let v: [Any] = (0...n).map { i in
            let t = Double(i) / fps
            let beam = 0.1 * seg(t, 0.15, 0.45) * (1 - seg(t, 1.6, 1.9))           // faint amber with the beam
            let ribbons = seg(t, 3.6, 4.2) * 0.8
            let pulse = sin(clamp(seg(t, 4.7, 5.15)) * .pi) * 0.25
            let handover = 1 - ease(seg(t, 5.2, 5.9))                               // live glow takes over
            return Float(max(beam, (ribbons + pulse) * handover))
        }
        return track("opacity", v, times, duration: introTotal)
    }

    /// Outro glow: the live glow gathers into a soft warm line at the bottom centre, then fades.
    static func outroGlow(from current: [CGColor]) -> [CAKeyframeAnimation] {
        let off = NSColor.black.cgColor
        let warm = NSColor(srgbRed: 1, green: 0.8, blue: 0.75, alpha: 1).cgColor
        let c = current.count >= 5 ? current : ring(off, off, off, off)
        let colours = CAKeyframeAnimation(keyPath: "colors")
        colours.values = [c, ring(off, c[1], warm, c[3]), ring(off, off, warm, off), ring(off, off, off, off)]
        colours.keyTimes = [0, 0.23, 0.47, 1]
        colours.duration = outroTotal
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [Float(0.9), Float(1), Float(0.5), Float(0)]
        opacity.keyTimes = [0, 0.33, 0.67, 1]
        opacity.duration = outroTotal
        return [colours, opacity]
    }

    /// Builds both plans, the text bitmaps and the CA code paths once at launch, so even the first
    /// intro plays without a hitch.
    @MainActor static func prewarm(pill: CGSize, touchBar: CGSize?) {
        let host = CALayer()
        _ = build(in: host, size: pill, stripCount: 40, dustCount: 60, reduceMotion: false)
        _ = buildOutro(in: host, size: pill, stripCount: 30, reduceMotion: false)
        _ = glowColours()
        if let tb = touchBar {
            _ = build(in: host, size: tb, stripCount: 100, dustCount: 120, reduceMotion: false, textScale: 1.8)
            _ = buildOutro(in: host, size: tb, stripCount: 80, reduceMotion: false)
        }
    }
}

extension CGFloat {
    func clamped(_ a: CGFloat, _ b: CGFloat) -> CGFloat { Swift.min(b, Swift.max(a, self)) }
}

/// The pill version: a layer-hosting view, built once when the intro/outro starts; snapshots can
/// freeze any moment.
struct CinemaIntroCA: NSViewRepresentable {
    let started: Date
    var fixedTime: Double?
    let size: CGSize
    var outro = false

    func makeNSView(context: Context) -> IntroView {
        let v = IntroView(frame: CGRect(origin: .zero, size: size))
        v.setup(size: size, started: started, fixedTime: fixedTime, outro: outro)
        return v
    }
    func updateNSView(_ v: IntroView, context: Context) { v.freeze(at: fixedTime) }

    final class IntroView: NSView {
        private var timeline: CALayer?
        override var isFlipped: Bool { true }

        func setup(size: CGSize, started: Date, fixedTime: Double?, outro: Bool) {
            let host = CALayer()
            layer = host
            wantsLayer = true
            let reduce = MainActor.assumeIsolated { Look.shared.reduceMotion }
            let tl = outro ? IntroH.buildOutro(in: host, size: size, stripCount: 30, reduceMotion: reduce)
                           : IntroH.build(in: host, size: size, stripCount: 40, dustCount: 60, reduceMotion: reduce)
            timeline = tl
            if let f = fixedTime { freeze(at: f) }
            else {
                let elapsed = max(0, Date().timeIntervalSince(started))
                tl.beginTime = tl.convertTime(CACurrentMediaTime(), from: nil) - elapsed
            }
        }

        func freeze(at t: Double?) {
            guard let t, let tl = timeline else { return }
            tl.speed = 0
            tl.timeOffset = t
            tl.beginTime = 0
        }
    }
}
