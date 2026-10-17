import AppKit
import SwiftUI
import Observation
import ImageIO

// MARK: - Options

enum GlowStyle: String, Codable, CaseIterable { case rainbow, accent, music }

enum AccentTheme: String, Codable, CaseIterable, Identifiable {
    case coral, ocean, mint, violet, gold, wallpaper
    var id: String { rawValue }
    var title: String {
        switch self {
        case .coral: "Coral"; case .ocean: "Ocean"; case .mint: "Mint"
        case .violet: "Violet"; case .gold: "Gold"; case .wallpaper: "Match Wallpaper"
        }
    }
    /// Tuned per matte: brighter on Dark Matte, deeper on White Matte for contrast.
    @MainActor func color(dark: Bool) -> NSColor {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        switch self {
        case .coral: return dark ? c(1.00, 0.48, 0.40) : c(0.87, 0.30, 0.24)
        case .ocean: return dark ? c(0.30, 0.64, 1.00) : c(0.00, 0.43, 0.86)
        case .mint: return dark ? c(0.38, 0.90, 0.72) : c(0.00, 0.58, 0.43)
        case .violet: return dark ? c(0.70, 0.56, 1.00) : c(0.49, 0.30, 0.90)
        case .gold: return dark ? c(1.00, 0.80, 0.32) : c(0.72, 0.50, 0.00)
        case .wallpaper: return Look.shared.wallpaperColor(dark: dark)
        }
    }
}

// MARK: - Look state (accent, wallpaper colour, music palette)

@Observable @MainActor
final class Look {
    static let shared = Look()
    var wallpaperBase: NSColor = NSColor(srgbRed: 0.30, green: 0.64, blue: 1, alpha: 1)
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Look.shared.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        })
        for n in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Look.shared.refreshWallpaperIfNeeded() }
            })
        }
        refreshWallpaperIfNeeded()
    }

    func refreshWallpaperIfNeeded() {
        guard AppSettings.shared.prefs.accent == .wallpaper else { timer?.invalidate(); timer = nil; return }
        if timer == nil {
            // No public "wallpaper changed" notification; re-sample every 10 minutes (cheap).
            let t = Timer(timeInterval: 600, repeats: true) { _ in MainActor.assumeIsolated { Look.shared.sampleWallpaper() } }
            t.tolerance = 120
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        sampleWallpaper()
    }

    /// Reads the current desktop picture file (NSWorkspace.desktopImageURL) and takes its
    /// dominant colour from a small thumbnail. No screen-capture API is used anywhere, so
    /// Glance never needs Screen Recording. Runs off the main thread.
    func sampleWallpaper() {
        guard let screen = NSScreen.screens.first, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        Task.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 64,
                  ] as CFDictionary),
                  let c = NSImage(cgImage: thumb, size: .zero).dominantColors(count: 1).first else { return }
            await MainActor.run { withAnimation(.easeInOut(duration: 0.8)) { Look.shared.wallpaperBase = c } }
        }
    }

    func wallpaperColor(dark: Bool) -> NSColor { Look.tune(wallpaperBase, dark: dark) }

    /// Keeps any colour readable on the chosen matte.
    static func tune(_ c: NSColor, dark: Bool) -> NSColor {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { s = 0.12 } // near-grey wallpapers still get a hint of colour
        return dark ? NSColor(hue: h, saturation: min(max(s, 0.45), 0.8), brightness: max(b, 0.88), alpha: 1)
                    : NSColor(hue: h, saturation: min(max(s, 0.6), 0.95), brightness: min(max(b, 0.45), 0.7), alpha: 1)
    }

    // MARK: Current colours

    var accentNS: NSColor {
        let p = AppSettings.shared.prefs
        if p.footballMode && p.matchdayTheme && FootballService.shared.isMatchday, let team = FootballService.shared.team {
            let tc = team.displayColor
            return p.theme == .darkMatte ? tc : (tc.blended(withFraction: 0.25, of: .black) ?? tc)
        }
        if p.accent == .wallpaper { _ = wallpaperBase } // observe
        return p.accent.color(dark: p.theme == .darkMatte)
    }

    /// 2-3 colours for music-driven styling; accent when nothing plays or the option is off.
    var musicPalette: [NSColor] {
        let p = AppSettings.shared.prefs
        let dark = p.theme == .darkMatte
        let np = NowPlaying.shared
        // Music colours only while a track with artwork is actually playing; otherwise the accent.
        if p.musicColors, np.isPlaying, let art = np.artwork {
            let cols = art.dominantColors(count: 3).map { Look.tune($0, dark: dark) }
            if !cols.isEmpty { return cols }
        }
        let a = accentNS
        return [a, a.blended(withFraction: 0.35, of: dark ? .white : .black) ?? a]
    }

    var musicPrimary: Color { Color(nsColor: musicPalette[0]) }
    /// Identity for animating palette changes between tracks.
    var paletteKey: String { musicPalette.map { $0.description }.joined() }
}

// MARK: - Dominant colours (hue-bucket clustering on a 32 px thumbnail, cached per image)

nonisolated(unsafe) private var paletteKey: UInt8 = 0

extension NSImage {
    func dominantColors(count: Int) -> [NSColor] {
        if let cached = objc_getAssociatedObject(self, &paletteKey) as? [NSColor], cached.count >= count {
            return Array(cached.prefix(count))
        }
        let side = 32
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        struct Bucket { var r = 0.0, g = 0.0, b = 0.0, w = 0.0 }
        var buckets = [Bucket](repeating: Bucket(), count: 12)
        var avg = Bucket()
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            let c = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            avg.r += r; avg.g += g; avg.b += b; avg.w += 1
            guard s > 0.18, v > 0.18 else { continue }
            let w = Double(s * v)
            let k = min(11, Int(h * 12))
            buckets[k].r += r * w; buckets[k].g += g * w; buckets[k].b += b * w; buckets[k].w += w
        }
        var out = buckets.enumerated().filter { $0.element.w > 0.5 }
            .sorted { $0.element.w > $1.element.w }
            .map { NSColor(srgbRed: $0.element.r / $0.element.w, green: $0.element.g / $0.element.w, blue: $0.element.b / $0.element.w, alpha: 1) }
        if out.isEmpty, avg.w > 0 {
            out = [NSColor(srgbRed: avg.r / avg.w, green: avg.g / avg.w, blue: avg.b / avg.w, alpha: 1)]
        }
        let result = Array(out.prefix(3))
        objc_setAssociatedObject(self, &paletteKey, result, .OBJC_ASSOCIATION_RETAIN)
        return Array(result.prefix(count))
    }
}

// MARK: - Feedback (haptics, optional soft UI sounds)

@MainActor
enum Feedback {
    static func haptic(_ p: NSHapticFeedbackManager.FeedbackPattern = .generic) {
        guard AppSettings.shared.prefs.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now)
    }
    /// Only built-in system sounds ("Pop", "Tink"), off by default.
    static func sound(_ name: String) {
        guard AppSettings.shared.prefs.uiSounds, IslandContext.shared.soundsAllowed, let s = NSSound(named: name) else { return }
        s.volume = 0.35
        s.play()
    }
}

// MARK: - Glow edge (Core Animation: conic gradient rotating under a pre-blurred mask)

enum GlowFlash: Equatable { case done, deny, timer }

struct GlowConfig: Equatable {
    var colors: [NSColor]
    var intensity: CGFloat     // 0...1
    var rotates: Bool
    var period: CFTimeInterval
    var pulse: CFTimeInterval? // pulse period, if pulsing
    var ear: CGFloat
    var radius: CGFloat
}

struct GlowEdge: NSViewRepresentable {
    var config: GlowConfig
    /// Room around the island for the soft spread and bloom (they must never reach the frame edge,
    /// or the rasterised mask is cut into a rectangle).
    static let pad: CGFloat = 64

    func makeNSView(context: Context) -> GlowLayerView { GlowLayerView() }
    func updateNSView(_ v: GlowLayerView, context: Context) { v.apply(config) }

    /// Colour layer only: a conic gradient rotated by Core Animation (render server, no app
    /// work per frame). Its shape comes from a SwiftUI mask built from the island's own
    /// animatable IslandShape, so the glow follows the panel exactly during every spring.
    final class GlowLayerView: NSView {
        private let container = CALayer()
        private let gradient = CAGradientLayer()
        private let gradientB = CAGradientLayer()   // crossfade partner for Cinema colours
        private var showingA = true
        private var current: GlowConfig?
        private var lastConfig: GlowConfig?
        private var cinemaActive = false
        private var paused = false
        private var observers: [NSObjectProtocol] = []

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(container)
            for g in [gradient, gradientB] {
                container.addSublayer(g)
                g.type = .conic
                g.startPoint = CGPoint(x: 0.5, y: 0.5)
                g.endPoint = CGPoint(x: 0.5, y: 0)
            }
            gradientB.opacity = 0
            container.opacity = 0
            MainActor.assumeIsolated { GlowRegistry.view = self }
            let ws = NSWorkspace.shared.notificationCenter
            observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.setPaused(true) })
            observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.setPaused(false) })
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self, weak w] _ in
                self?.setPaused(!(w?.occlusionState.contains(.visible) ?? true))
            })
        }

        /// Freezes the render-server animation (screen asleep or island hidden).
        private func setPaused(_ p: Bool) {
            guard p != paused else { return }
            paused = p
            if p {
                let t = container.convertTime(CACurrentMediaTime(), from: nil)
                container.speed = 0
                container.timeOffset = t
            } else {
                let t = container.timeOffset
                container.speed = 1
                container.timeOffset = 0
                container.beginTime = 0
                container.beginTime = container.convertTime(CACurrentMediaTime(), from: nil) - t
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.frame = bounds
            // Just big enough to cover the view at any rotation (smaller layer = less to composite).
            // The conic centre sits at the island's own centre (hidden under the pill), so the
            // colour seams never show in the spread below it.
            let cy = max(0, (bounds.height - GlowEdge.pad) / 2)
            let side = 2 * hypot(bounds.width / 2, bounds.height - cy) + 8
            for g in [gradient, gradientB] {
                g.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                g.position = CGPoint(x: bounds.midX, y: cy)
            }
            CATransaction.commit()
        }

        /// Cinema mode: spatial colours straight from the screen (top, right, bottom, left).
        func pushCinema(colors: [NSColor], intensity: CGFloat, cut: Bool = false) {
            if !cinemaActive {
                cinemaActive = true
                for g in [gradient, gradientB] {
                    g.removeAnimation(forKey: "spin"); g.removeAnimation(forKey: "pulse"); g.removeAnimation(forKey: "colors")
                    g.transform = CATransform3DIdentity
                }
            }
            guard colors.count == 4 else { return }
            // Conic gradient runs clockwise from the top; repeat the first stop to close the ring.
            let ring = [colors[0], colors[1], colors[2], colors[3], colors[0]].map { $0.cgColor }
            // New colours drawn once into the hidden layer, then a cheap opacity crossfade.
            // Scene cut: follow almost at once; otherwise glide over one update interval.
            let d = cut ? 0.07 : MainActor.assumeIsolated { Power.shared.colourInterval }
            CAQuiet.crossfade(gradient, gradientB, showingA: &showingA, set: { ($0 as? CAGradientLayer)?.colors = ring }, duration: d)
            lastIntensity = Float(intensity)
            // During the intro the live glow stays off; the intro's own ring plays instead.
            let holding = introEnd.map { Date() < $0 } ?? false
            CAQuiet.animate(container, "opacity", to: holding ? Float(0) : Float(intensity), duration: holding ? 0.1 : d)
        }

        // MARK: Cinema intro H: the ring follows the ribbons, then hands over to the live colours.
        private let introRing = CAGradientLayer()
        private var introEnd: Date?
        private var lastIntensity: Float = 0.9

        /// Outro: the live glow gathers into a soft warm line at the bottom centre, then fades out.
        func playOutro() {
            let current = ((showingA ? gradient : gradientB).colors as? [CGColor]) ?? []
            CAQuiet.animate(container, "opacity", to: Float(0), duration: 0.2)
            if introRing.superlayer == nil {
                introRing.type = .conic
                introRing.startPoint = CGPoint(x: 0.5, y: 0.5); introRing.endPoint = CGPoint(x: 0.5, y: 0)
                layer?.addSublayer(introRing)
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            introRing.speed = 1; introRing.timeOffset = 0
            introRing.bounds = gradient.bounds; introRing.position = gradient.position
            introRing.opacity = 0
            CATransaction.commit()
            let start = introRing.convertTime(CACurrentMediaTime(), from: nil)
            for a in IntroH.outroGlow(from: current) {
                a.beginTime = start; a.fillMode = .both; a.isRemovedOnCompletion = false
                a.preferredFrameRateRange = IntroH.rate
                introRing.add(a, forKey: a.keyPath)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + IntroH.outroDuration + 0.1) { [weak self] in self?.introRing.removeAllAnimations() }
        }

        /// Snapshots: hold the intro ring at a given moment.
        func freezeIntro(at t: Double) {
            if introRing.animation(forKey: "colors") == nil { playIntro() }
            introRing.speed = 0
            introRing.timeOffset = t
            introRing.beginTime = 0
        }

        func playIntro() {
            introRing.speed = 1; introRing.timeOffset = 0
            let reduce = MainActor.assumeIsolated { Look.shared.reduceMotion }
            let total = IntroH.duration
            introEnd = Date().addingTimeInterval(total - 0.6)
            CAQuiet.animate(container, "opacity", to: Float(0), duration: 0.15)
            if !reduce {
                if introRing.superlayer == nil {
                    introRing.type = .conic
                    introRing.startPoint = CGPoint(x: 0.5, y: 0.5); introRing.endPoint = CGPoint(x: 0.5, y: 0)
                    layer?.addSublayer(introRing)
                }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                introRing.frame = gradient.frame
                introRing.bounds = gradient.bounds; introRing.position = gradient.position
                introRing.opacity = 0
                CATransaction.commit()
                let start = introRing.convertTime(CACurrentMediaTime(), from: nil)
                for a in [IntroH.glowColours(), IntroH.glowOpacity()] {
                    a.beginTime = start
                    a.fillMode = .both; a.isRemovedOnCompletion = false
                    a.preferredFrameRateRange = IntroH.rate
                    introRing.add(a, forKey: a.keyPath)
                }
            }
            // Live Ambilight fades in as the line opens (5.15-5.8 in the preview).
            DispatchQueue.main.asyncAfter(deadline: .now() + total - 0.6) { [weak self] in
                guard let self else { return }
                self.introEnd = nil
                if self.cinemaActive { CAQuiet.animate(self.container, "opacity", to: self.lastIntensity, duration: 0.6) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.1) { [weak self] in self?.introRing.removeAllAnimations() }
        }

        /// Bass thump: a brief intensity pulse (no size change).
        func thump() {
            guard cinemaActive else { return }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = min(1, container.opacity + 0.35)
            a.toValue = container.opacity
            a.duration = 0.25
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            container.add(a, forKey: "thump")
        }

        func endCinema() {
            guard cinemaActive else { return }
            cinemaActive = false
            // Back to a single layer for the normal glow.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if !showingA { gradient.colors = gradientB.colors; showingA = true }
            gradient.opacity = 1; gradientB.opacity = 0
            gradient.removeAllAnimations(); gradientB.removeAllAnimations()
            CATransaction.commit()
            current = nil
            if let c = lastConfig { apply(c) }
        }

        func apply(_ c: GlowConfig) {
            lastConfig = c
            if cinemaActive { return } // Cinema owns the colours while it runs
            let old = current
            current = c
            let cg = (c.colors + [c.colors.first ?? .white]).map { $0.cgColor }
            if old?.colors != c.colors {
                let anim = CABasicAnimation(keyPath: "colors")
                anim.fromValue = gradient.colors
                anim.toValue = cg
                anim.duration = 0.8
                gradient.add(anim, forKey: "colors")
                gradient.colors = cg
            }
            if old?.intensity != c.intensity {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = container.presentation()?.opacity ?? container.opacity
                a.toValue = Float(c.intensity)
                a.duration = 0.3
                container.add(a, forKey: "fade")
                container.opacity = Float(c.intensity)
            }
            if old?.rotates != c.rotates || old?.period != c.period {
                gradient.removeAnimation(forKey: "spin")
                if c.rotates {
                    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                    spin.fromValue = 0
                    spin.toValue = Double.pi * 2
                    spin.duration = c.period
                    spin.repeatCount = .infinity
                    spin.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                    gradient.add(spin, forKey: "spin")
                }
            }
            if old?.pulse != c.pulse {
                gradient.removeAnimation(forKey: "pulse")
                if let p = c.pulse {
                    let a = CABasicAnimation(keyPath: "opacity")
                    a.fromValue = 0.45
                    a.toValue = 1
                    a.duration = p / 2
                    a.autoreverses = true
                    a.repeatCount = .infinity
                    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    a.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                    gradient.add(a, forKey: "pulse")
                }
            }
        }
    }
}

/// The glow's shape: the island outline itself (same animatable shape and frame as the
/// panel), stroked and softened. Used as a SwiftUI mask over GlowEdge.
struct GlowMask: View {
    let size: CGSize
    /// feat/controls: the island outline from IslandGeometry (Notch or Pill).
    let outline: IslandOutline
    /// Room above the island for the glow (Pill with a height offset).
    var topPad: CGFloat = 0
    var strength: GlowStrength = .normal

    var body: some View {
        // (soft spread width, soft blur, rim width, rim blur, bloom width, bloom blur, bloom opacity)
        let p: (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, Double) = {
            switch strength {
            case .subtle: return (8, 7, 2, 2, 0, 0, 0)
            case .normal: return (12, 9, 3, 2.5, 0, 0, 0)
            case .rich: return (30, 12, 4.5, 1.4, 42, 19, 1.0)   // bright rim + deep soft spread + outer bloom
            }
        }()
        return ZStack(alignment: .top) {
            if p.6 > 0 {
                IslandGlowEdge(outline: outline)
                    .stroke(style: StrokeStyle(lineWidth: p.4, lineCap: .round))
                    .frame(width: size.width, height: size.height)
                    .blur(radius: p.5)
                    .opacity(p.6)
            }
            IslandGlowEdge(outline: outline)
                .stroke(style: StrokeStyle(lineWidth: p.0, lineCap: .round))
                .frame(width: size.width, height: size.height)
                .blur(radius: p.1)
            IslandGlowEdge(outline: outline)
                .stroke(style: StrokeStyle(lineWidth: p.2, lineCap: .round))
                .frame(width: size.width, height: size.height)
                .blur(radius: p.3)
        }
        .padding(.top, topPad)
        .frame(width: size.width + GlowEdge.pad * 2, height: size.height + GlowEdge.pad + topPad, alignment: .top)
        // Rasterise the blurred mask once per size: the gradient underneath can change colour
        // without the window server re-blurring anything. The pad keeps every blur inside.
        .drawingGroup()
    }
}

/// The island outline WITHOUT its top edge (that edge is the screen edge): right side, bottom
/// corners, left side. Stroking the closed shape drew a flat band along the top of the screen.
struct GlowOutline: Shape {
    var ear: CGFloat
    var radius: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let e = min(ear, w / 4)
        let r = min(radius, (w - 2 * e) / 2, h - e)
        var p = Path()
        p.move(to: CGPoint(x: w - e, y: 0))
        p.addLine(to: CGPoint(x: w - e, y: h - r))
        p.addCurve(to: CGPoint(x: w - e - r, y: h), control1: CGPoint(x: w - e, y: h - r * 0.28), control2: CGPoint(x: w - e - r * 0.28, y: h))
        p.addLine(to: CGPoint(x: e + r, y: h))
        p.addCurve(to: CGPoint(x: e, y: h - r), control1: CGPoint(x: e + r * 0.28, y: h), control2: CGPoint(x: e, y: h - r * 0.28))
        p.addLine(to: CGPoint(x: e, y: 0))
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

@MainActor
enum GlowPalette {
    static let rainbow: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.42, blue: 0.62, alpha: 1), NSColor(srgbRed: 1.00, green: 0.62, blue: 0.30, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.86, blue: 0.40, alpha: 1), NSColor(srgbRed: 0.40, green: 0.90, blue: 0.62, alpha: 1),
        NSColor(srgbRed: 0.32, green: 0.74, blue: 1.00, alpha: 1), NSColor(srgbRed: 0.62, green: 0.48, blue: 1.00, alpha: 1),
    ]

    static func config(model: IslandModel, open: Bool, ear: CGFloat, radius: CGFloat) -> GlowConfig? {
        let p = AppSettings.shared.prefs
        let look = Look.shared
        let still = look.reduceMotion || Power.shared.saving
        let accent = look.accentNS
        // Event states override the style.
        if model.currentPermission != nil {
            let amber = NSColor(srgbRed: 1, green: 0.66, blue: 0.18, alpha: 1)
            return GlowConfig(colors: [amber, NSColor(srgbRed: 1, green: 0.5, blue: 0.1, alpha: 1), amber], intensity: 1,
                              rotates: !still, period: 6, pulse: still ? nil : 1.4, ear: ear, radius: radius)
        }
        if let c = model.celebration {
            // Intro H drives its own glow ring (keyframes); the normal glow stays off meanwhile.
            if c.kind.isCinemaCA {
                return GlowConfig(colors: c.kind.glow, intensity: 0, rotates: false, period: 10, pulse: nil, ear: ear, radius: radius)
            }
            return GlowConfig(colors: c.kind.glow, intensity: 1, rotates: !still, period: 4, pulse: still ? nil : 0.8, ear: ear, radius: radius)
        }
        if let f = model.glowFlash {
            let c: NSColor
            switch f {
            case .done: c = NSColor(srgbRed: 0.25, green: 0.88, blue: 0.45, alpha: 1)
            case .deny: c = NSColor(srgbRed: 1, green: 0.27, blue: 0.27, alpha: 1)
            case .timer: c = accent
            }
            return GlowConfig(colors: [c, c.blended(withFraction: 0.3, of: .white) ?? c, c], intensity: 1,
                              rotates: !still, period: 5, pulse: still ? nil : (f == .timer ? 1.0 : 0.6), ear: ear, radius: radius)
        }
        guard p.glowEnabled || p.cinemaExtension, open || p.glowWhenClosed || ChromeAmbilight.shared.engaged else { return nil }
        let colors: [NSColor]
        switch p.glowStyle {
        case _ where p.footballMode && p.matchdayTheme && FootballService.shared.isMatchday && FootballService.shared.team != nil:
            let tc = FootballService.shared.team?.displayColor ?? accent
            colors = [tc, .white, tc, tc.blended(withFraction: 0.35, of: .black) ?? tc]
        case .rainbow: colors = rainbow
        case .accent: colors = [accent, accent.blended(withFraction: 0.4, of: .white) ?? accent, accent.blended(withFraction: 0.3, of: .black) ?? accent]
        case .music: colors = look.musicPalette
        }
        // Closed pill: still glow by default (zero ongoing cost); it rotates while open.
        return GlowConfig(colors: colors, intensity: open ? 0.9 : 0.5, rotates: !still && (open || p.glowAnimateClosed),
                          period: open ? 10 : 16, pulse: nil, ear: ear, radius: radius)
    }
}
