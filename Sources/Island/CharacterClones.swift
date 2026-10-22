import AppKit
import SwiftUI

// MARK: - Shadow clones (one per running Claude Code subagent)
//
// Drawn with Core Animation like the rig: every motion (pop-in, the working bob, the wave, the
// done hop, the poof) runs in the render server, nothing ticks per frame in the app. A view
// with no clones has no layers and no animations, and every view freezes its layers while its
// window is hidden or covered. Stills only (Reduce Motion, Low Power Mode): poses change, nothing moves.
//
// Places: the island (a cell per clone with its label and status, beside the character on
// Home), the closed pill (a small face per clone and the count) and the Touch Bar (clones run
// along the strip; one that needs you stops and waves).

enum CloneLook {
    static let blue = NSColor(red: 0.56, green: 0.77, blue: 1, alpha: 1)
    static let orange = NSColor(red: 1, green: 0.6, blue: 0.3, alpha: 1)
    static let green = NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)
    static let grey = NSColor(red: 0.79, green: 0.8, blue: 0.84, alpha: 1)

    /// The character pose a clone shows.
    static func pose(_ p: CharacterClone.Phase?) -> CharacterState {
        switch p {
        case .working: .thinking
        case .needsYou: .approval
        case .done: .finished
        case nil: .idle
        }
    }

    static func status(_ p: CharacterClone.Phase?) -> (String, NSColor) {
        switch p {
        case .working: ("working", blue)
        case .needsYou: ("needs you", orange)
        case .done: ("done", green)
        case nil: ("starting", grey)
        }
    }

    /// The pose as a still (clones never play videos), from the Touch Bar stills when `compact`.
    @MainActor static func art(_ pack: CharacterPack, _ state: CharacterState, compact: Bool = false) -> CGImage? {
        if compact, let s = pack.compactSource(for: state, alt: false) ?? pack.compactSource(for: .idle, alt: false), let cg = pack.image(s) { return cg }
        for st in [state, .idle] {
            if let s = pack.media(for: st, alt: false)?.still, let cg = pack.image(s) { return cg }
        }
        return nil
    }

    /// How a clone differs from the main character: a pale fox spirit, a translucent smoke
    /// clone, or a tiny mochi in sakura pink, kusa green or plain white.
    struct Tint { var color: NSColor?; var amount: Float; var opacity: Float; var outline: Float }
    static func tint(_ effect: CloneEffect, ordinal: Int) -> Tint {
        switch effect {
        case .foxfire: Tint(color: NSColor(red: 0.62, green: 0.8, blue: 1, alpha: 1), amount: 0.42, opacity: 0.96, outline: 0.55)
        case .smoke: Tint(color: NSColor(red: 0.62, green: 0.68, blue: 0.8, alpha: 1), amount: 0.3, opacity: 0.84, outline: 0.6)
        case .flour:
            switch ordinal % 3 {
            case 1: Tint(color: NSColor(red: 0.98, green: 0.78, blue: 0.85, alpha: 1), amount: 0.5, opacity: 1, outline: 0.25)
            case 2: Tint(color: NSColor(red: 0.8, green: 0.9, blue: 0.74, alpha: 1), amount: 0.5, opacity: 1, outline: 0.25)
            default: Tint(color: nil, amount: 0, opacity: 1, outline: 0.25)
            }
        }
    }

    /// The marker at a clone's feet and the colour of its puff.
    static func wispColor(_ effect: CloneEffect) -> NSColor {
        switch effect {
        case .foxfire: NSColor(red: 0.47, green: 0.75, blue: 1, alpha: 0.5)
        case .smoke: NSColor(white: 1, alpha: 0.26)
        case .flour: NSColor(red: 1, green: 0.86, blue: 0.9, alpha: 0.34)
        }
    }

    /// Which clones get a place when there is room for `cells`: oldest first, the overflow folds
    /// into a "+N" cell, and a clone that needs you always keeps its place.
    static func visible(_ all: [CharacterClone], cells: Int) -> (shown: [CharacterClone], more: Int) {
        guard all.count > cells, cells > 0 else { return (all, 0) }
        var shown = Array(all.prefix(cells - 1))
        if let ask = all.first(where: { $0.phase == .needsYou }), !shown.contains(ask) { shown[shown.count - 1] = ask }
        return (shown, all.count - shown.count)
    }
}

// MARK: - Animation helpers

@MainActor
enum CloneAnim {
    static func kf(_ path: String, _ values: [Any], times: [NSNumber]? = nil, dur: CFTimeInterval, repeats: Bool = false, delay: CFTimeInterval = 0,
                   reverse: Bool = false, timing: CAMediaTimingFunctionName = .easeInEaseOut, offset: CFTimeInterval = 0,
                   hold: Bool = false, key: String? = nil, on layer: CALayer) {
        let a = CAKeyframeAnimation(keyPath: path)
        a.values = values
        if let times { a.keyTimes = times }
        a.duration = dur
        a.repeatCount = repeats ? .infinity : 1
        a.autoreverses = reverse
        a.timeOffset = offset
        a.timingFunctions = Array(repeating: CAMediaTimingFunction(name: timing), count: max(values.count - 1, 1))
        a.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        a.fillMode = hold ? .both : .backwards
        a.isRemovedOnCompletion = !hold
        a.preferredFrameRateRange = CharacterRigView.rate
        layer.add(a, forKey: key ?? path)
    }

    static func deg(_ d: Double) -> Double { d * .pi / 180 }

    /// A soft round blob (smoke, flour) or a flame (fox-fire) for puffs.
    static func blob(_ effect: CloneEffect, size z: CGFloat) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.type = .radial
        switch effect {
        case .smoke:
            g.bounds = CGRect(x: 0, y: 0, width: z, height: z)
            g.colors = [NSColor.white.cgColor, NSColor(red: 0.91, green: 0.92, blue: 0.95, alpha: 1).cgColor, NSColor(red: 0.91, green: 0.92, blue: 0.95, alpha: 0).cgColor]
            g.locations = [0, 0.62, 1]
            g.startPoint = CGPoint(x: 0.42, y: 0.38)
        case .foxfire:
            g.bounds = CGRect(x: 0, y: 0, width: z * 0.62, height: z)
            g.colors = [NSColor.white.cgColor, NSColor(red: 0.75, green: 0.89, blue: 1, alpha: 1).cgColor,
                        NSColor(red: 0.35, green: 0.66, blue: 1, alpha: 0.55).cgColor, NSColor(red: 0.35, green: 0.66, blue: 1, alpha: 0).cgColor]
            g.locations = [0, 0.5, 0.8, 1]
            g.startPoint = CGPoint(x: 0.5, y: 0.66)
            g.cornerRadius = z * 0.31
        case .flour:
            g.bounds = CGRect(x: 0, y: 0, width: z * 0.45, height: z * 0.45)
            g.colors = [NSColor(red: 1, green: 0.96, blue: 0.97, alpha: 1).cgColor, NSColor(red: 1, green: 0.87, blue: 0.9, alpha: 1).cgColor,
                        NSColor(red: 1, green: 0.87, blue: 0.9, alpha: 0).cgColor]
            g.locations = [0, 0.66, 1]
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
        }
        g.endPoint = CGPoint(x: 1, y: 1)
        return g
    }

    /// (dx, dy, size, delay) for the 7 blobs of a puff, as in the approved design.
    static let puffSpec: [(CGFloat, CGFloat, CGFloat, CFTimeInterval)] =
        [(-30, -18, 30, 0), (28, -20, 28, 0.02), (-12, -34, 26, 0.04), (16, -6, 34, 0), (-26, 4, 24, 0.05), (34, 2, 22, 0.06), (0, -12, 40, 0)]

    /// A one-off burst of smoke, fox-fire or rice flour around `centre` in `host` (scaled by `k`).
    /// The blobs remove themselves.
    static func puff(_ effect: CloneEffect, in host: CALayer, at centre: CGPoint, scale k: CGFloat) {
        for (dx, dy, z, dl) in puffSpec {
            let b = blob(effect, size: z * k)
            b.position = centre
            b.opacity = 0
            host.addSublayer(b)
            let dur: CFTimeInterval = effect == .foxfire ? 0.95 : 0.8
            let tx = dx * k * (effect == .foxfire ? 0.8 : 1)
            let ty = (dy + (effect == .foxfire ? -14 : effect == .flour ? 3 : 0)) * k
            let endScale = effect == .foxfire ? 0.7 : 1.5
            kf("opacity", [0, effect == .foxfire ? 1 : 0.95, 0], times: [0, effect == .foxfire ? 0.22 : 0.18, 1], dur: dur, delay: dl, timing: .easeOut, on: b)
            kf("transform.scale", [0.2, endScale], dur: dur, delay: dl, timing: .easeOut, on: b)
            kf("transform.translation.x", [0, tx], dur: dur, delay: dl, timing: .easeOut, on: b)
            kf("transform.translation.y", [effect == .foxfire ? 4 * k : 0, ty], dur: dur, delay: dl, timing: .easeOut, on: b)
            DispatchQueue.main.asyncAfter(deadline: .now() + dur + dl + 0.05) { b.removeFromSuperlayer() }
        }
    }

    /// The pop-in: smoke pops, fox-fire flickers in, a mochi splits off from the left.
    static func spawn(_ effect: CloneEffect, on l: CALayer) {
        switch effect {
        case .smoke:
            kf("opacity", [0, 1, 1], times: [0, 0.25, 1], dur: 0.9, timing: .easeOut, key: "spawn1", on: l)
            kf("transform.scale", [0.35, 1.1, 0.97, 1], times: [0, 0.25, 0.55, 1], dur: 0.9, timing: .easeOut, key: "spawn2", on: l)
        case .foxfire:
            kf("opacity", [0, 0.4, 1, 0.55, 1, 1], times: [0, 0.3, 0.45, 0.6, 0.75, 1], dur: 1, key: "spawn3", on: l)
            kf("transform.scale", [0.5, 0.8, 1.06, 1, 1], times: [0, 0.3, 0.45, 0.75, 1], dur: 1, key: "spawn4", on: l)
            kf("transform.translation.y", [6, 2, 0, 0], times: [0, 0.3, 0.45, 1], dur: 1, key: "spawn5", on: l)
        case .flour:
            kf("opacity", [0, 1, 1], times: [0, 0.3, 1], dur: 0.95, key: "spawn6", on: l)
            kf("transform.translation.x", [-46, -14, 0, 0], times: [0, 0.3, 0.62, 1], dur: 0.95, timing: .easeOut, key: "spawn7", on: l)
            kf("transform.scale.x", [0.4, 1.3, 0.88, 1], times: [0, 0.3, 0.62, 1], dur: 0.95, timing: .easeOut, key: "spawn8", on: l)
            kf("transform.scale.y", [0.3, 0.68, 1.14, 1], times: [0, 0.3, 0.62, 1], dur: 0.95, timing: .easeOut, key: "spawn9", on: l)
        }
    }

    /// The vanish as the puff covers it.
    static func vanish(on l: CALayer) {
        kf("opacity", [1, 0], dur: 0.45, timing: .easeIn, hold: true, key: "v-opacity", on: l)
        kf("transform.scale.x", [1, 0.6], dur: 0.45, timing: .easeIn, hold: true, key: "v-sx", on: l)
        kf("transform.scale.y", [1, 0.75], dur: 0.45, timing: .easeIn, hold: true, key: "v-sy", on: l)
        kf("transform.translation.y", [0, -4], dur: 0.45, timing: .easeIn, hold: true, key: "v-ty", on: l)
    }

    /// The happy hop when a clone's agent is done.
    static func hop(on l: CALayer) {
        let t: [NSNumber] = [0, 0.14, 0.36, 0.56, 0.72, 1]
        kf("transform.translation.y", [0, 2, -11, 0, 0, 0], times: t, dur: 1.1, delay: 0.05, on: l)
        kf("transform.scale.x", [1, 1.08, 0.94, 1.08, 0.98, 1], times: t, dur: 1.1, delay: 0.05, on: l)
        kf("transform.scale.y", [1, 0.9, 1.07, 0.92, 1.02, 1], times: t, dur: 1.1, delay: 0.05, on: l)
    }

    /// The wave while a clone's agent needs you: a sway from the feet and a little hop now and then.
    static func wave(on l: CALayer) {
        kf("transform.rotation.z", [deg(-5), deg(5)], dur: 0.42, repeats: true, reverse: true, on: l)
        kf("transform.translation.y", [0, 0, -3, 0, 0], times: [0, 0.7, 0.78, 0.88, 1], dur: 1.9, repeats: true, key: "attention", on: l)
    }

    /// A small breath while working (each clone a little out of step with the others).
    static func work(on l: CALayer, ordinal: Int) {
        let off = Double(ordinal % 5) * 0.41
        kf("transform.scale.y", [1, 1.035, 1], dur: 2.6, repeats: true, offset: off, on: l)
        kf("transform.translation.y", [0, -1.2, 0], dur: 2.6, repeats: true, offset: off, on: l)
    }
}

// MARK: - One clone (island cell)

/// One clone's layers: glow, wisp at the feet, the tinted art, then its label and status.
@MainActor
final class CloneCellLayers {
    static let size = CGSize(width: 60, height: 132)
    let root = CALayer()
    let body = CALayer()
    private let art = CALayer()
    private let tintLayer = CALayer()
    private let tintMask = CALayer()
    private let glow = CAGradientLayer()
    private let wisp = CAGradientLayer()
    private let label = CATextLayer()
    private let status = CATextLayer()
    private let dot = CALayer()
    let key: String
    private(set) var phase: CharacterClone.Phase?
    private var packID = ""
    private var labelText = ""
    private var ordinal = 0
    /// Art box (bottom-centred) inside the cell.
    private var artBox: CGRect {
        let s: CGFloat = 58
        return CGRect(x: (Self.size.width - s) / 2, y: Self.size.height - 30 - s, width: s, height: s)
    }

    init(key: String, scale: CGFloat) {
        self.key = key
        root.bounds = CGRect(origin: .zero, size: Self.size)
        root.anchorPoint = .zero
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 1)
        glow.opacity = 0
        wisp.type = .radial
        wisp.startPoint = CGPoint(x: 0.5, y: 0.5); wisp.endPoint = CGPoint(x: 1, y: 1)
        body.anchorPoint = CGPoint(x: 0.5, y: 1)
        art.contentsGravity = .resizeAspect
        art.shadowColor = NSColor.white.cgColor
        art.shadowOffset = .zero
        art.shadowRadius = 1.4
        tintMask.contentsGravity = .resizeAspect
        tintLayer.mask = tintMask
        for t in [label, status] {
            t.alignmentMode = .center
            t.truncationMode = .end
            t.contentsScale = scale
        }
        dot.cornerRadius = 2.5
        dot.shadowOffset = .zero; dot.shadowRadius = 2.5; dot.shadowOpacity = 1
        root.addSublayer(glow)
        root.addSublayer(wisp)
        root.addSublayer(body)
        body.addSublayer(art)
        body.addSublayer(tintLayer)
        root.addSublayer(label)
        root.addSublayer(dot)
        root.addSublayer(status)
        layoutParts()
    }

    private func layoutParts() {
        let a = artBox
        body.bounds = CGRect(origin: .zero, size: a.size)
        body.position = CGPoint(x: a.midX, y: a.maxY)
        art.frame = body.bounds
        tintLayer.frame = body.bounds
        tintMask.frame = tintLayer.bounds
        glow.frame = CGRect(x: a.midX - 44, y: a.maxY - 74, width: 88, height: 88)
        wisp.frame = CGRect(x: a.midX - 24, y: a.maxY - 7, width: 48, height: 11)
        label.frame = CGRect(x: 0, y: Self.size.height - 27, width: Self.size.width, height: 14)
    }

    /// Feet of the clone in cell coordinates (where puffs start).
    var puffCentre: CGPoint { CGPoint(x: artBox.midX, y: artBox.maxY - 24) }

    func configure(_ c: CharacterClone?, pack: CharacterPack, stills: Bool, moreCount: Int = 0) {
        let packChanged = pack.id != packID
        packID = pack.id
        let effect = pack.cloneEffect
        let newPhase = c?.phase
        let phaseChanged = newPhase != phase || packChanged
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let c {
            ordinal = c.ordinal
            if c.label != labelText || packChanged {
                labelText = c.label
                label.string = NSAttributedString(string: c.label, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                                                 .foregroundColor: NSColor(white: 1, alpha: 0.92)])
            }
            if phaseChanged {
                let cg = CloneLook.art(pack, CloneLook.pose(newPhase))
                art.contents = cg
                tintMask.contents = cg
                let t = CloneLook.tint(effect, ordinal: ordinal)
                tintLayer.backgroundColor = t.color?.cgColor
                tintLayer.opacity = t.color == nil ? 0 : t.amount
                body.opacity = t.opacity
                art.shadowOpacity = t.outline
                wisp.colors = [CloneLook.wispColor(effect).cgColor, CloneLook.wispColor(effect).withAlphaComponent(0).cgColor]
                let (txt, col) = CloneLook.status(newPhase)
                setStatus(txt, col)
            }
        }
        CATransaction.commit()
        guard phaseChanged else { return }
        let old = phase
        phase = newPhase
        // Motion for the new phase.
        body.removeAnimation(forKey: "transform.rotation.z")
        body.removeAnimation(forKey: "attention")
        body.removeAnimation(forKey: "transform.scale.y")
        body.removeAnimation(forKey: "transform.translation.y")
        glow.removeAllAnimations()
        wisp.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        switch newPhase {
        case .needsYou:
            glow.colors = [NSColor(red: 1, green: 0.5, blue: 0.16, alpha: 0.5).cgColor, NSColor(red: 1, green: 0.5, blue: 0.16, alpha: 0).cgColor]
            glow.opacity = stills ? 0.85 : 1
            art.shadowColor = NSColor(red: 1, green: 0.6, blue: 0.25, alpha: 1).cgColor
            art.shadowOpacity = 0.9; art.shadowRadius = 4
        case .done:
            glow.colors = [NSColor(red: 0.4, green: 0.83, blue: 0.6, alpha: 0.32).cgColor, NSColor(red: 0.4, green: 0.83, blue: 0.6, alpha: 0).cgColor]
            glow.opacity = stills ? 0.7 : 0
            art.shadowColor = NSColor.white.cgColor; art.shadowRadius = 1.4
        default:
            glow.opacity = 0
            art.shadowColor = NSColor.white.cgColor; art.shadowRadius = 1.4
        }
        CATransaction.commit()
        guard !stills else { return }
        CloneAnim.kf("transform.translation.x", [-2, 3], dur: 1.6, repeats: true, reverse: true, offset: Double(ordinal % 4) * 0.4, on: wisp)
        CloneAnim.kf("transform.scale.x", [0.9, 1.1], dur: 1.6, repeats: true, reverse: true, offset: Double(ordinal % 4) * 0.4, key: "ws", on: wisp)
        switch newPhase {
        case .needsYou:
            CloneAnim.kf("opacity", [0.45, 1, 0.45], dur: 1.3, repeats: true, hold: true, on: glow)
            CloneAnim.kf("transform.scale", [0.92, 1.06, 0.92], dur: 1.3, repeats: true, on: glow)
            CloneAnim.wave(on: body)
        case .done:
            CloneAnim.kf("opacity", [0, 1, 0.45, 0], dur: 1.4, hold: true, on: glow)
            CloneAnim.hop(on: body)
        case .working:
            CloneAnim.work(on: body, ordinal: ordinal)
        case nil:
            break
        }
        _ = old
    }

    private func setStatus(_ txt: String, _ col: NSColor) {
        let s = NSAttributedString(string: txt, attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: col])
        status.string = s
        let w = ceil(s.size().width)
        let total = w + 8
        let x0 = (Self.size.width - total) / 2
        dot.frame = CGRect(x: x0, y: Self.size.height - 10.5, width: 5, height: 5)
        dot.backgroundColor = col.cgColor
        dot.shadowColor = col.cgColor
        status.alignmentMode = .left
        status.frame = CGRect(x: x0 + 8, y: Self.size.height - 13.5, width: w + 2, height: 12)
    }

    func spawn(effect: CloneEffect, stills: Bool) {
        guard !stills else { return }
        CloneAnim.spawn(effect, on: body)
        CloneAnim.kf("opacity", [0, 1], dur: 0.35, timing: .easeOut, key: "fade-in", on: label)
        CloneAnim.kf("opacity", [0, 1], dur: 0.35, timing: .easeOut, key: "fade-in", on: status)
        CloneAnim.puff(effect, in: root, at: puffCentre, scale: 0.8)
    }

    /// The clone goes: a puff of its pack's effect, the vanish, then the layers are removed.
    func poof(effect: CloneEffect, stills: Bool) {
        if stills { root.removeFromSuperlayer(); return }
        for l in [glow, wisp] { l.removeAllAnimations(); l.opacity = 0 }
        CloneAnim.vanish(on: body)
        CloneAnim.kf("opacity", [1, 0], dur: 0.5, delay: 0.25, hold: true, key: "fade-out", on: label)
        CloneAnim.kf("opacity", [1, 0], dur: 0.5, delay: 0.25, hold: true, key: "fade-out", on: status)
        CloneAnim.kf("opacity", [1, 0], dur: 0.5, delay: 0.25, hold: true, key: "fade-out", on: dot)
        CloneAnim.puff(effect, in: root, at: puffCentre, scale: 0.8)
        let r = root
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { r.removeFromSuperlayer() }
    }
}

// MARK: - The "+N" cell

@MainActor
final class CloneMoreLayers {
    let root = CALayer()
    private let cloud = CALayer()
    private var puffs: [CAGradientLayer] = []
    private let count = CATextLayer()
    private let label = CATextLayer()
    private let status = CATextLayer()
    private var effect: CloneEffect?

    init(scale: CGFloat) {
        root.bounds = CGRect(origin: .zero, size: CloneCellLayers.size)
        root.anchorPoint = .zero
        cloud.bounds = CGRect(x: 0, y: 0, width: 58, height: 50)
        cloud.position = CGPoint(x: CloneCellLayers.size.width / 2, y: CloneCellLayers.size.height - 30 - 28)
        root.addSublayer(cloud)
        for r in [CGRect(x: 2, y: 20, width: 25, height: 25), CGRect(x: 14, y: 5, width: 31, height: 31),
                  CGRect(x: 32, y: 16, width: 25, height: 25), CGRect(x: 12, y: 25, width: 34, height: 23)] {
            let g = CAGradientLayer()
            g.type = .radial
            g.frame = r
            g.cornerRadius = min(r.width, r.height) / 2
            g.startPoint = CGPoint(x: 0.4, y: 0.35); g.endPoint = CGPoint(x: 1.1, y: 1.1)
            cloud.addSublayer(g)
            puffs.append(g)
        }
        count.frame = CGRect(x: 0, y: 17, width: 58, height: 22)
        count.alignmentMode = .center
        cloud.addSublayer(count)
        label.frame = CGRect(x: 0, y: CloneCellLayers.size.height - 27, width: CloneCellLayers.size.width, height: 14)
        status.frame = CGRect(x: 0, y: CloneCellLayers.size.height - 13.5, width: CloneCellLayers.size.width, height: 12)
        for t in [count, label, status] { t.contentsScale = scale; t.alignmentMode = .center }
        root.addSublayer(label)
        root.addSublayer(status)
    }

    func configure(_ n: Int, effect: CloneEffect, stills: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if effect != self.effect {
            let cols: [NSColor]
            switch effect {
            case .foxfire: cols = [NSColor(red: 0.96, green: 0.98, blue: 1, alpha: 1), NSColor(red: 0.73, green: 0.87, blue: 1, alpha: 1), NSColor(red: 0.44, green: 0.68, blue: 1, alpha: 1)]
            case .flour: cols = [.white, NSColor(red: 0.98, green: 0.87, blue: 0.9, alpha: 1), NSColor(red: 0.93, green: 0.73, blue: 0.78, alpha: 1)]
            case .smoke: cols = [.white, NSColor(red: 0.89, green: 0.91, blue: 0.94, alpha: 1), NSColor(red: 0.79, green: 0.81, blue: 0.85, alpha: 1)]
            }
            for p in puffs { p.colors = cols.map(\.cgColor); p.locations = [0, 0.55, 1] }
            cloud.shadowColor = effect == .foxfire ? NSColor(red: 0.43, green: 0.7, blue: 1, alpha: 1).cgColor : NSColor.black.cgColor
            cloud.shadowOpacity = effect == .foxfire ? 0.45 : 0
            cloud.shadowRadius = 6; cloud.shadowOffset = .zero
            self.effect = effect
            cloud.removeAllAnimations()
            if !stills {
                CloneAnim.kf("transform.translation.y", [0, -2], dur: 1.8, repeats: true, reverse: true, on: cloud)
                CloneAnim.kf("transform.scale", [1, 1.03], dur: 1.8, repeats: true, reverse: true, on: cloud)
            }
        }
        count.string = NSAttributedString(string: "+\(n)", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .heavy),
                                                                         .foregroundColor: NSColor(red: 0.16, green: 0.16, blue: 0.2, alpha: 1)])
        label.string = NSAttributedString(string: "\(n) more", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                                            .foregroundColor: NSColor(white: 1, alpha: 0.92)])
        status.string = NSAttributedString(string: "working", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: CloneLook.blue])
        CATransaction.commit()
    }
}

// MARK: - Island strip

/// The clones beside the character on Home: one cell each, oldest first, then "+N".
final class CloneStripView: NSView {
    static let maxCells = 4
    private let host = CALayer()
    private var cells: [String: CloneCellLayers] = [:]
    private var more: CloneMoreLayers?
    private var running = false
    private var occlusionObs: NSObjectProtocol?
    var externallyPaused = false { didSet { updateRunning() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        host.anchorPoint = .zero
        layer?.addSublayer(host)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Cells are 132 pt tall, bottom-aligned in the view.
        host.frame = CGRect(x: 0, y: bounds.height - CloneCellLayers.size.height, width: bounds.width, height: CloneCellLayers.size.height)
        CATransaction.commit()
    }

    func apply(_ all: [CharacterClone], pack: CharacterPack?, stills: Bool) {
        guard let pack else { clearAll(); updateRunning(); return }
        let (shown, extra) = CloneLook.visible(all, cells: Self.maxCells)
        let allKeys = Set(all.map(\.key)), shownKeys = Set(shown.map(\.key))
        let effect = pack.cloneEffect
        // Gone for good: poof. Folded into "+N": a quick fade.
        for (k, c) in cells where !shownKeys.contains(k) {
            cells[k] = nil
            if allKeys.contains(k) {
                CloneAnim.kf("opacity", [1, 0], dur: 0.25, hold: true, key: "fold", on: c.root)
                let r = c.root
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { r.removeFromSuperlayer() }
            } else {
                c.poof(effect: effect, stills: stills)
            }
        }
        var x: CGFloat = 0
        for c in shown {
            let cell: CloneCellLayers
            let isNew = cells[c.key] == nil
            if let existing = cells[c.key] { cell = existing } else {
                cell = CloneCellLayers(key: c.key, scale: scale)
                cells[c.key] = cell
                host.addSublayer(cell.root)
            }
            cell.configure(c, pack: pack, stills: stills)
            move(cell.root, to: x, animated: !isNew && !stills)
            if isNew { cell.spawn(effect: effect, stills: stills) }
            x += CloneCellLayers.size.width
        }
        if extra > 0 {
            let m = more ?? CloneMoreLayers(scale: scale)
            if more == nil { more = m; host.addSublayer(m.root); move(m.root, to: x, animated: false)
                if !stills { CloneAnim.kf("opacity", [0, 1], dur: 0.3, key: "in", on: m.root) }
            } else { move(m.root, to: x, animated: !stills) }
            m.configure(extra, effect: effect, stills: stills)
        } else if let m = more {
            more = nil
            m.root.removeFromSuperlayer()
        }
        updateRunning()
    }

    private func move(_ l: CALayer, to x: CGFloat, animated: Bool) {
        let p = CGPoint(x: x, y: 0)
        guard l.position != p else { return }
        if animated {
            let a = CABasicAnimation(keyPath: "position")
            a.fromValue = NSValue(point: l.presentation()?.position ?? l.position)
            a.toValue = NSValue(point: p)
            a.duration = 0.45
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.25, 0.5, 1)
            a.preferredFrameRateRange = CharacterRigView.rate
            l.add(a, forKey: "move")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.position = p
        CATransaction.commit()
    }

    private func clearAll() {
        cells.values.forEach { $0.root.removeFromSuperlayer() }
        cells = [:]
        more?.root.removeFromSuperlayer(); more = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObs { NotificationCenter.default.removeObserver(o); occlusionObs = nil }
        if let w = window {
            occlusionObs = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunning() }
            }
        }
        updateRunning()
    }

    /// Frozen (speed 0) while hidden, covered or empty, like the rig.
    private func updateRunning() {
        let visible = window != nil && (window?.occlusionState.contains(.visible) ?? false) && !externallyPaused && !(cells.isEmpty && more == nil)
        guard visible != running else { return }
        running = visible
        CloneAnim.setRunning(host, visible)
    }
}

extension CloneAnim {
    /// Pause or resume a layer tree in place (the rig's technique).
    static func setRunning(_ l: CALayer, _ on: Bool) {
        if on {
            guard l.speed == 0 else { return }
            let paused = l.timeOffset
            l.speed = 1
            l.timeOffset = 0
            l.beginTime = 0
            l.beginTime = l.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else {
            guard l.speed != 0 else { return }
            let t = l.convertTime(CACurrentMediaTime(), from: nil)
            l.speed = 0
            l.timeOffset = t
        }
    }
}

/// SwiftUI wrapper for the island strip (follows the live engine).
struct CloneStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> CloneStripView { CloneStripView(frame: .zero) }
    func updateNSView(_ v: CloneStripView, context: Context) {
        let e = CharacterEngine.shared
        v.externallyPaused = e.screensAsleep || AppSettings.shared.prefs.islandHidden
        v.apply(e.frame.helpers, pack: e.pack, stills: e.frame.stills)
    }
}

// MARK: - Closed pill: a small face per clone

/// Up to four overlapping round faces, one per clone, ringed white (working), orange and
/// bobbing (needs you) or green (done). Faces pop in and shrink away.
final class CloneHeadsView: NSView {
    static let maxHeads = 4
    static let size: CGFloat = 15
    static let step: CGFloat = 10
    private var heads: [String: CALayer] = [:]
    private var phases: [String: CharacterClone.Phase] = [:]
    private var running = false
    private var occlusionObs: NSObjectProtocol?
    private let host = CALayer()
    var externallyPaused = false { didSet { updateRunning() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        host.anchorPoint = .zero
        layer?.addSublayer(host)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    static func width(_ n: Int) -> CGFloat { n == 0 ? 0 : size + CGFloat(min(n, maxHeads) - 1) * step + 4 }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        host.frame = bounds
        CATransaction.commit()
    }

    func apply(_ all: [CharacterClone], pack: CharacterPack?, stills: Bool) {
        guard let pack else { heads.values.forEach { $0.removeFromSuperlayer() }; heads = [:]; phases = [:]; updateRunning(); return }
        var shown = Array(all.prefix(Self.maxHeads))
        if let ask = all.first(where: { $0.phase == .needsYou }), !shown.contains(ask) { shown[shown.count - 1] = ask }
        let keys = Set(shown.map(\.key))
        for (k, h) in heads where !keys.contains(k) {
            heads[k] = nil; phases[k] = nil
            if stills { h.removeFromSuperlayer(); continue }
            CloneAnim.kf("transform.scale", [1, 1.25, 0.2], times: [0, 0.3, 1], dur: 0.4, timing: .easeIn, hold: true, key: "out-s", on: h)
            CloneAnim.kf("opacity", [1, 1, 0], times: [0, 0.3, 1], dur: 0.4, hold: true, key: "out-o", on: h)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { h.removeFromSuperlayer() }
        }
        let face = CloneLook.art(pack, .idle, compact: true)
        for (i, c) in shown.enumerated() {
            let isNew = heads[c.key] == nil
            let h = heads[c.key] ?? makeHead(face, pack: pack, ordinal: c.ordinal)
            if isNew { heads[c.key] = h; host.insertSublayer(h, at: 0) }
            let p = CGPoint(x: 2 + Self.size / 2 + CGFloat(i) * Self.step, y: bounds.height / 2)
            if !isNew && !stills && h.position != p {
                let a = CABasicAnimation(keyPath: "position"); a.fromValue = NSValue(point: h.presentation()?.position ?? h.position); a.duration = 0.4
                a.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.25, 0.5, 1); h.add(a, forKey: "move")
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            h.position = p
            h.zPosition = CGFloat(i)
            CATransaction.commit()
            if isNew && !stills {
                CloneAnim.kf("transform.scale", [0.2, 1.2, 1], times: [0, 0.6, 1], dur: 0.55, timing: .easeOut, key: "in", on: h)
                CloneAnim.kf("opacity", [0, 1], dur: 0.2, key: "in-o", on: h)
            }
            if phases[c.key] != c.phase { phases[c.key] = c.phase; setPhase(h, c.phase, stills: stills) }
        }
        updateRunning()
    }

    private func makeHead(_ face: CGImage?, pack: CharacterPack, ordinal: Int) -> CALayer {
        let h = CALayer()
        h.bounds = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        h.cornerRadius = Self.size / 2
        h.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1).cgColor
        h.borderWidth = 1.25
        h.shadowOffset = .zero
        let art = CALayer()
        art.frame = h.bounds
        art.cornerRadius = Self.size / 2
        art.masksToBounds = true
        art.contents = face
        art.contentsGravity = .resizeAspectFill
        // The upper middle of the still: the face.
        art.contentsRect = CGRect(x: 0.18, y: 0.02, width: 0.64, height: 0.6)
        let t = CloneLook.tint(pack.cloneEffect, ordinal: ordinal)
        if let col = t.color {
            let tl = CALayer(); tl.frame = h.bounds; tl.backgroundColor = col.cgColor; tl.opacity = t.amount
            let m = CALayer(); m.frame = h.bounds; m.contents = face; m.contentsGravity = .resizeAspectFill; m.contentsRect = art.contentsRect
            tl.mask = m
            art.addSublayer(tl)
        }
        h.addSublayer(art)
        return h
    }

    private func setPhase(_ h: CALayer, _ p: CharacterClone.Phase, stills: Bool) {
        h.removeAnimation(forKey: "ask-y"); h.removeAnimation(forKey: "ask-s")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        switch p {
        case .working:
            h.borderColor = NSColor(white: 1, alpha: 0.62).cgColor
            h.shadowColor = NSColor(red: 0.86, green: 0.92, blue: 1, alpha: 1).cgColor; h.shadowOpacity = 0.25; h.shadowRadius = 3
        case .needsYou:
            h.borderColor = CloneLook.orange.cgColor
            h.shadowColor = NSColor(red: 1, green: 0.55, blue: 0.2, alpha: 1).cgColor; h.shadowOpacity = 0.95; h.shadowRadius = 4.5
        case .done:
            h.borderColor = CloneLook.green.cgColor
            h.shadowColor = CloneLook.green.cgColor; h.shadowOpacity = 0.7; h.shadowRadius = 4
        }
        CATransaction.commit()
        if p == .needsYou && !stills {
            CloneAnim.kf("transform.translation.y", [0, -1.5, 0], dur: 1.3, repeats: true, key: "ask-y", on: h)
            CloneAnim.kf("transform.scale", [1, 1.08, 1], dur: 1.3, repeats: true, key: "ask-s", on: h)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObs { NotificationCenter.default.removeObserver(o); occlusionObs = nil }
        if let w = window {
            occlusionObs = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunning() }
            }
        }
        updateRunning()
    }

    private func updateRunning() {
        let visible = window != nil && (window?.occlusionState.contains(.visible) ?? false) && !externallyPaused && !heads.isEmpty
        guard visible != running else { return }
        running = visible
        CloneAnim.setRunning(host, visible)
    }
}

struct CloneHeads: NSViewRepresentable {
    func makeNSView(context: Context) -> CloneHeadsView { CloneHeadsView(frame: .zero) }
    func updateNSView(_ v: CloneHeadsView, context: Context) {
        let e = CharacterEngine.shared
        v.externallyPaused = e.screensAsleep || AppSettings.shared.prefs.islandHidden
        v.apply(e.frame.helpers, pack: e.pack, stills: e.frame.stills)
    }
}

// MARK: - Touch Bar: clones running along the strip

/// The clones on the Touch Bar: each runs left to right across a lane and wraps round, a short
/// label trailing behind it. One that needs you stops and waves in an orange glow, a finished
/// one hops, then poofs. Stills: they stand in a row instead. The lane is a layer of the strip.
@MainActor
final class CloneRunners {
    static let maxRunners = 6
    static let spacing: CGFloat = 98
    static let speed: CGFloat = 92
    let lane = CALayer()
    private let fadeL = CAGradientLayer(), fadeR = CAGradientLayer()
    private final class Runner {
        let root = CALayer(), body = CALayer(), art = CALayer(), tint = CALayer(), tintMask = CALayer(), glow = CAGradientLayer(), label = CATextLayer()
        var phase: CharacterClone.Phase?
        var running = false
        var ordinal = 0
    }
    private var runners: [String: Runner] = [:]
    private var width: CGFloat = 0

    init() {
        lane.masksToBounds = true
        lane.isGeometryFlipped = true
        for (g, flip) in [(fadeL, false), (fadeR, true)] {
            g.startPoint = CGPoint(x: flip ? 1 : 0, y: 0.5); g.endPoint = CGPoint(x: flip ? 0 : 1, y: 0.5)
            g.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
            g.zPosition = 50
            lane.addSublayer(g)
        }
    }

    var isEmpty: Bool { runners.isEmpty }
    private var loop: CGFloat { width + 70 }

    func layout(_ frame: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let changed = frame.width != width
        lane.frame = frame
        width = frame.width
        fadeL.frame = CGRect(x: 0, y: 0, width: 16, height: frame.height)
        fadeR.frame = CGRect(x: frame.width - 16, y: 0, width: 16, height: frame.height)
        CATransaction.commit()
        if changed { for r in runners.values where r.running { r.running = false; r.root.removeAnimation(forKey: "run") } }
    }

    func apply(_ all: [CharacterClone], pack: CharacterPack?, stills: Bool, scale: CGFloat) {
        guard let pack, width > 0 else { runners.values.forEach { $0.root.removeFromSuperlayer() }; runners = [:]; return }
        var shown = Array(all.prefix(Self.maxRunners))
        if let ask = all.first(where: { $0.phase == .needsYou }), !shown.contains(ask) { shown[shown.count - 1] = ask }
        let keys = Set(shown.map(\.key)), allKeys = Set(all.map(\.key))
        let effect = pack.cloneEffect
        for (k, r) in runners where !keys.contains(k) {
            runners[k] = nil
            if stills || allKeys.contains(k) { r.root.removeFromSuperlayer(); continue }
            freeze(r)
            CloneAnim.vanish(on: r.body)
            CloneAnim.kf("opacity", [1, 0], dur: 0.3, hold: true, key: "lab-out", on: r.label)
            CloneAnim.puff(effect, in: r.root, at: CGPoint(x: 15, y: 15), scale: 0.42)
            let l = r.root
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { l.removeFromSuperlayer() }
        }
        for (i, c) in shown.enumerated() {
            let r: Runner
            let isNew = runners[c.key] == nil
            if let e = runners[c.key] { r = e } else {
                r = makeRunner(c, scale: scale)
                runners[c.key] = r
                lane.addSublayer(r.root)
                // Stills stand in a row; runners start behind the last one on the lane.
                let x = stills ? 34 + CGFloat(i) * 92 : spawnX()
                CATransaction.begin(); CATransaction.setDisableActions(true)
                r.root.position = CGPoint(x: x, y: 15)
                CATransaction.commit()
            }
            if stills {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                r.root.position = CGPoint(x: 34 + CGFloat(i) * 92, y: 15)
                CATransaction.commit()
            }
            r.ordinal = c.ordinal
            if r.phase != c.phase || isNew {
                setPhase(r, c.phase, pack: pack, stills: stills, fresh: isNew)
            }
            if isNew && !stills {
                CloneAnim.spawn(.smoke, on: r.body)
                CloneAnim.puff(effect, in: r.root, at: CGPoint(x: 15, y: 15), scale: 0.42)
            }
        }
    }

    private func makeRunner(_ c: CharacterClone, scale: CGFloat) -> Runner {
        let r = Runner()
        r.root.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
        r.glow.type = .radial
        r.glow.startPoint = CGPoint(x: 0.5, y: 0.5); r.glow.endPoint = CGPoint(x: 1, y: 1)
        r.glow.colors = [NSColor(red: 1, green: 0.5, blue: 0.16, alpha: 0.6).cgColor, NSColor(red: 1, green: 0.5, blue: 0.16, alpha: 0).cgColor]
        r.glow.frame = CGRect(x: -6, y: 0, width: 42, height: 30)
        r.glow.opacity = 0
        r.body.anchorPoint = CGPoint(x: 0.5, y: 1)
        r.body.bounds = CGRect(x: 0, y: 0, width: 36, height: 36)
        r.body.position = CGPoint(x: 15, y: 33)
        r.art.frame = r.body.bounds
        r.art.contentsGravity = .resizeAspect
        r.art.shadowColor = NSColor.white.cgColor; r.art.shadowOffset = .zero; r.art.shadowRadius = 1
        r.tint.frame = r.body.bounds
        r.tintMask.frame = r.body.bounds
        r.tintMask.contentsGravity = .resizeAspect
        r.tint.mask = r.tintMask
        r.body.addSublayer(r.art); r.body.addSublayer(r.tint)
        r.label.string = NSAttributedString(string: c.label, attributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
                                                                           .foregroundColor: NSColor(white: 1, alpha: 0.62)])
        r.label.alignmentMode = .right
        r.label.contentsScale = scale
        r.label.frame = CGRect(x: -82, y: 10, width: 80, height: 12)
        r.root.addSublayer(r.glow); r.root.addSublayer(r.body); r.root.addSublayer(r.label)
        return r
    }

    /// Lane x for a newcomer: one spacing behind the last runner (or near the start).
    private func spawnX() -> CGFloat {
        let xs = runners.values.filter { $0.root.superlayer != nil }.map { $0.root.presentation()?.position.x ?? $0.root.position.x }
        guard let last = xs.min() else { return 26 }
        var x = last - Self.spacing
        while x < -40 { x += loop }
        return x
    }

    private func setPhase(_ r: Runner, _ p: CharacterClone.Phase?, pack: CharacterPack, stills: Bool, fresh: Bool) {
        r.phase = p
        let runs = p == .working && !stills
        let still: CGImage? = runs ? (CloneLook.art(pack, .music) ?? CloneLook.art(pack, .thinking)) : CloneLook.art(pack, CloneLook.pose(p))
        let t = CloneLook.tint(pack.cloneEffect, ordinal: r.ordinal)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        r.art.contents = still
        r.tintMask.contents = still
        r.tint.backgroundColor = t.color?.cgColor
        r.tint.opacity = t.color == nil ? 0 : t.amount
        r.body.opacity = t.opacity
        r.art.shadowOpacity = t.outline
        r.glow.opacity = p == .needsYou ? 1 : 0
        r.label.opacity = p == .needsYou ? 0 : 1
        r.root.zPosition = p == .needsYou ? 10 : 0
        CATransaction.commit()
        for k in ["bob", "transform.rotation.z", "attention", "transform.translation.y", "transform.scale.x", "transform.scale.y"] { r.body.removeAnimation(forKey: k) }
        r.glow.removeAllAnimations()
        guard !stills else { return }
        if runs {
            CloneAnim.kf("transform.translation.y", [0, -2.2, 0], dur: 0.34, repeats: true, offset: Double(r.ordinal % 3) * 0.11, key: "bob", on: r.body)
            // Start running once the pop-in has played.
            if fresh { DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self, weak r] in if let r, r.phase == .working { self?.run(r) } } } else { run(r) }
        } else {
            freeze(r)
            switch p {
            case .needsYou:
                CloneAnim.kf("opacity", [0.45, 1, 0.45], dur: 1.3, repeats: true, hold: true, on: r.glow)
                CloneAnim.wave(on: r.body)
            case .done: CloneAnim.hop(on: r.body)
            default: break
            }
        }
    }

    /// Run from where the runner stands, wrapping round the lane.
    private func run(_ r: Runner) {
        guard !r.running, r.root.superlayer != nil, width > 0 else { return }
        r.running = true
        let x0 = r.root.presentation()?.position.x ?? r.root.position.x
        let dur = Double(loop / Self.speed)
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = -40; a.toValue = -40 + loop
        a.duration = dur
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        a.timeOffset = Double((x0 + 40) / loop) * dur
        a.beginTime = r.root.convertTime(CACurrentMediaTime(), from: nil)
        a.preferredFrameRateRange = CharacterRigView.rate
        r.root.add(a, forKey: "run")
    }

    /// Stop where it is (to wave, hop or poof).
    private func freeze(_ r: Runner) {
        guard r.running else { return }
        r.running = false
        var x = r.root.presentation()?.position.x ?? r.root.position.x
        x = min(max(x, 20), width - 20)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        r.root.position = CGPoint(x: x, y: 15)
        CATransaction.commit()
        r.root.removeAnimation(forKey: "run")
    }
}
