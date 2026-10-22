import AppKit

/// Mochi: Glance's own placeholder character, a soft rice-cake blob drawn in code (no image
/// files). Each pose is rendered once at 3x and cached by the pack.
@MainActor
enum MochiArt {
    static let pack = CharacterPack(
        id: "builtin:mochi", name: "Mochi",
        summary: "A soft little rice cake. Snacks when idle, bobs to your music, charges a glowing orb while Claude thinks.",
        credit: "Original Glance character.", folder: nil,
        media: [
            "idle": m("idle", 92), "idleAlt": m("snack", 92), "sleeping": m("sleeping", 56, bottom: 8),
            "music": m("music", 96), "movie": m("poof", 84, bottom: 8), "thinking": m("thinking", 96),
            "approval": m("approval", 96), "finished": m("finished", 96),
        ],
        compact: [:], cloneEffect: .flour)

    private static func m(_ key: String, _ h: CGFloat, bottom: CGFloat = 0) -> CharacterMedia {
        var x = CharacterMedia()
        x.still = .drawn(key)
        x.stillHeight = h
        x.stillBottom = bottom
        return x
    }

    /// Canvas in points (drawn at 3x). Wider canvases for poses with props.
    private static func canvas(_ key: String) -> CGSize {
        switch key {
        case "sleeping": CGSize(width: 120, height: 70)
        case "poof": CGSize(width: 120, height: 100)
        case "thinking", "music", "approval", "finished", "snack": CGSize(width: 110, height: 100)
        default: CGSize(width: 90, height: 100)
        }
    }

    static func image(_ key: String) -> CGImage? {
        let size = canvas(key), scale: CGFloat = 3
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // Top-left origin, like the rest of the rig.
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
        draw(key, ctx, size)
        return ctx.makeImage()
    }

    private static let cream = CGColor(red: 1, green: 0.97, blue: 0.93, alpha: 1)
    private static let shade = CGColor(red: 0.93, green: 0.86, blue: 0.82, alpha: 1)
    private static let ink = CGColor(red: 0.16, green: 0.12, blue: 0.14, alpha: 1)
    private static let blush = CGColor(red: 1, green: 0.55, blue: 0.62, alpha: 0.55)

    private static func draw(_ key: String, _ c: CGContext, _ s: CGSize) {
        switch key {
        case "poof": poof(c, s); return
        case "sleeping":
            body(c, CGRect(x: 20, y: 22, width: 80, height: 46))
            closedEyes(c, cx: 60, y: 46, gap: 22)
            // Nightcap.
            c.setFillColor(CGColor(red: 0.45, green: 0.5, blue: 0.95, alpha: 1))
            let cap = CGMutablePath()
            cap.move(to: CGPoint(x: 36, y: 30)); cap.addQuadCurve(to: CGPoint(x: 84, y: 30), control: CGPoint(x: 60, y: 14))
            cap.addQuadCurve(to: CGPoint(x: 104, y: 12), control: CGPoint(x: 96, y: 18))
            cap.addQuadCurve(to: CGPoint(x: 36, y: 30), control: CGPoint(x: 70, y: 4))
            c.addPath(cap); c.fillPath()
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fillEllipse(in: CGRect(x: 100, y: 8, width: 9, height: 9))
            return
        default: break
        }
        let cx: CGFloat = key == "idle" ? 45 : 50
        let blob = CGRect(x: cx - 36, y: 30, width: 72, height: 66)
        if key == "thinking" {
            // A glowing blue orb held to the side.
            let orb = CGPoint(x: 94, y: 58)
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [CGColor(red: 0.85, green: 0.95, blue: 1, alpha: 1), CGColor(red: 0.35, green: 0.65, blue: 1, alpha: 0.9),
                                        CGColor(red: 0.3, green: 0.55, blue: 1, alpha: 0)] as CFArray, locations: [0, 0.45, 1])!
            c.drawRadialGradient(g, startCenter: orb, startRadius: 0, endCenter: orb, endRadius: 16, options: [])
        }
        body(c, blob)
        switch key {
        case "finished":
            happyEyes(c, cx: cx, y: 60)
            nub(c, from: CGPoint(x: cx + 30, y: 66), to: CGPoint(x: cx + 44, y: 46))
            star(c, CGPoint(x: cx + 48, y: 36), 7)
        case "approval":
            eyes(c, cx: cx, y: 60, wide: true)
            nub(c, from: CGPoint(x: cx + 30, y: 64), to: CGPoint(x: cx + 46, y: 40))
        case "music":
            eyes(c, cx: cx, y: 61, wide: false)
            // Headphones.
            c.setStrokeColor(CGColor(red: 0.95, green: 0.45, blue: 0.4, alpha: 1)); c.setLineWidth(4)
            c.addArc(center: CGPoint(x: cx, y: 64), radius: 34, startAngle: .pi * 1.05, endAngle: .pi * 1.95, clockwise: false); c.strokePath()
            c.setFillColor(CGColor(red: 0.95, green: 0.45, blue: 0.4, alpha: 1))
            c.addPath(CGPath(roundedRect: CGRect(x: cx - 40, y: 56, width: 10, height: 18), cornerWidth: 4, cornerHeight: 4, transform: nil))
            c.addPath(CGPath(roundedRect: CGRect(x: cx + 30, y: 56, width: 10, height: 18), cornerWidth: 4, cornerHeight: 4, transform: nil))
            c.fillPath()
            note(c, CGPoint(x: cx + 46, y: 30))
        case "snack":
            eyes(c, cx: cx, y: 60, wide: false)
            // A dango stick.
            c.setStrokeColor(CGColor(red: 0.75, green: 0.6, blue: 0.4, alpha: 1)); c.setLineWidth(2)
            c.move(to: CGPoint(x: cx + 22, y: 84)); c.addLine(to: CGPoint(x: cx + 50, y: 34)); c.strokePath()
            let cols = [CGColor(red: 1, green: 0.7, blue: 0.78, alpha: 1), CGColor(gray: 0.98, alpha: 1), CGColor(red: 0.6, green: 0.85, blue: 0.55, alpha: 1)]
            for (i, col) in cols.enumerated() {
                let p = CGPoint(x: cx + 46 - CGFloat(i) * 7, y: 41 + CGFloat(i) * 12.5)
                c.setFillColor(col); c.fillEllipse(in: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
            }
        default:
            eyes(c, cx: cx, y: 60, wide: false)
        }
        cheeks(c, cx: cx, y: 70)
        mouth(c, cx: cx, y: 74, open: key == "finished" || key == "approval" || key == "snack")
    }

    private static func body(_ c: CGContext, _ r: CGRect) {
        // Soft shadow on the floor, then the blob with a little top shine.
        c.setFillColor(CGColor(gray: 0, alpha: 0.25))
        c.fillEllipse(in: CGRect(x: r.minX + 6, y: r.maxY - 6, width: r.width - 12, height: 8))
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX, y: r.maxY - 10))
        p.addCurve(to: CGPoint(x: r.midX, y: r.minY), control1: CGPoint(x: r.minX - 2, y: r.minY + r.height * 0.25), control2: CGPoint(x: r.minX + r.width * 0.2, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.maxY - 10), control1: CGPoint(x: r.maxX - r.width * 0.2, y: r.minY), control2: CGPoint(x: r.maxX + 2, y: r.minY + r.height * 0.25))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - 10), control: CGPoint(x: r.midX, y: r.maxY + 6))
        c.addPath(p)
        c.saveGState(); c.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [cream, shade] as CFArray, locations: [0.55, 1])!
        c.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
        c.setFillColor(CGColor(gray: 1, alpha: 0.85))
        c.fillEllipse(in: CGRect(x: r.minX + r.width * 0.22, y: r.minY + r.height * 0.12, width: r.width * 0.22, height: r.height * 0.12))
        c.restoreGState()
    }

    private static func eyes(_ c: CGContext, cx: CGFloat, y: CGFloat, wide: Bool) {
        c.setFillColor(ink)
        let h: CGFloat = wide ? 11 : 9
        for dx in [-12.0, 12.0] as [CGFloat] {
            c.fillEllipse(in: CGRect(x: cx + dx - 3.5, y: y - h / 2, width: 7, height: h))
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fillEllipse(in: CGRect(x: cx + dx - 1.5, y: y - h / 2 + 1.5, width: 2.6, height: 2.6))
            c.setFillColor(ink)
        }
    }

    private static func happyEyes(_ c: CGContext, cx: CGFloat, y: CGFloat) {
        c.setStrokeColor(ink); c.setLineWidth(2.6); c.setLineCap(.round)
        for dx in [-12.0, 12.0] as [CGFloat] {
            c.move(to: CGPoint(x: cx + dx - 5, y: y + 2)); c.addQuadCurve(to: CGPoint(x: cx + dx + 5, y: y + 2), control: CGPoint(x: cx + dx, y: y - 6))
        }
        c.strokePath()
    }

    private static func closedEyes(_ c: CGContext, cx: CGFloat, y: CGFloat, gap: CGFloat) {
        c.setStrokeColor(ink); c.setLineWidth(2.2); c.setLineCap(.round)
        for dx in [-gap / 2, gap / 2] {
            c.move(to: CGPoint(x: cx + dx - 5, y: y)); c.addQuadCurve(to: CGPoint(x: cx + dx + 5, y: y), control: CGPoint(x: cx + dx, y: y + 5))
        }
        c.strokePath()
    }

    private static func cheeks(_ c: CGContext, cx: CGFloat, y: CGFloat) {
        c.setFillColor(blush)
        c.fillEllipse(in: CGRect(x: cx - 27, y: y - 3, width: 10, height: 6))
        c.fillEllipse(in: CGRect(x: cx + 17, y: y - 3, width: 10, height: 6))
    }

    private static func mouth(_ c: CGContext, cx: CGFloat, y: CGFloat, open: Bool) {
        if open {
            c.setFillColor(CGColor(red: 0.85, green: 0.35, blue: 0.4, alpha: 1))
            let p = CGMutablePath()
            p.move(to: CGPoint(x: cx - 5, y: y - 1)); p.addQuadCurve(to: CGPoint(x: cx + 5, y: y - 1), control: CGPoint(x: cx, y: y + 9))
            p.closeSubpath(); c.addPath(p); c.fillPath()
        } else {
            c.setStrokeColor(ink); c.setLineWidth(1.8); c.setLineCap(.round)
            c.move(to: CGPoint(x: cx - 4, y: y)); c.addQuadCurve(to: CGPoint(x: cx + 4, y: y), control: CGPoint(x: cx, y: y + 4)); c.strokePath()
        }
    }

    private static func nub(_ c: CGContext, from: CGPoint, to: CGPoint) {
        c.setStrokeColor(shade); c.setLineWidth(11); c.setLineCap(.round)
        c.move(to: from); c.addLine(to: to); c.strokePath()
        c.setStrokeColor(cream); c.setLineWidth(8)
        c.move(to: from); c.addLine(to: to); c.strokePath()
    }

    private static func star(_ c: CGContext, _ p: CGPoint, _ r: CGFloat) {
        let path = CGMutablePath()
        for i in 0..<10 {
            let a = CGFloat(i) * .pi / 5 - .pi / 2, rr = i % 2 == 0 ? r : r * 0.42
            let q = CGPoint(x: p.x + cos(a) * rr, y: p.y + sin(a) * rr)
            i == 0 ? path.move(to: q) : path.addLine(to: q)
        }
        path.closeSubpath()
        c.setFillColor(CGColor(red: 1, green: 0.86, blue: 0.4, alpha: 1)); c.addPath(path); c.fillPath()
    }

    private static func note(_ c: CGContext, _ p: CGPoint) {
        c.setFillColor(CGColor(red: 0.75, green: 0.7, blue: 1, alpha: 1))
        c.fillEllipse(in: CGRect(x: p.x - 4, y: p.y + 8, width: 7, height: 5.5))
        c.fill(CGRect(x: p.x + 1.8, y: p.y - 2, width: 1.6, height: 12))
        c.fill(CGRect(x: p.x + 1.8, y: p.y - 2, width: 6, height: 2))
    }

    private static func poof(_ c: CGContext, _ s: CGSize) {
        let puffs: [(CGFloat, CGFloat, CGFloat)] = [(30, 60, 20), (55, 48, 26), (82, 58, 21), (45, 72, 18), (72, 74, 19), (60, 30, 15), (98, 70, 12), (18, 76, 11)]
        for (i, (x, y, r)) in puffs.enumerated() {
            c.setFillColor(CGColor(gray: i % 2 == 0 ? 0.93 : 0.84, alpha: 0.95))
            c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        c.setFillColor(CGColor(gray: 1, alpha: 0.9))
        c.fillEllipse(in: CGRect(x: 44, y: 34, width: 16, height: 10))
    }
}
