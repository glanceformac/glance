import AppKit
import SwiftUI
import Observation

// MARK: - Theme

struct Theme {
    let dark: Bool
    var accentNS: NSColor = .systemBlue
    var accent: Color { Color(nsColor: accentNS) }
    /// Text/icon colour placed on an accent fill.
    var onAccent: Color {
        let c = accentNS.usingColorSpace(.sRGB) ?? accentNS
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return lum > 0.6 ? Color(white: 0.08) : .white
    }
    var pill: Color { dark ? .black : Color(white: 0.97) }
    var tint: Color { dark ? Color.black.opacity(0.52) : Color.white.opacity(0.55) }
    var card: Color { dark ? Color.white.opacity(0.085) : Color.black.opacity(0.05) }
    var cardStroke: Color { dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06) }
    var primary: Color { dark ? .white : Color(white: 0.08) }
    var secondary: Color { dark ? Color.white.opacity(0.55) : Color.black.opacity(0.5) }
    var tertiary: Color { dark ? Color.white.opacity(0.3) : Color.black.opacity(0.28) }
    var accentFill: Color { dark ? .white : Color(white: 0.1) }
    var accentText: Color { dark ? .black : .white }
    /// Opaque fallback when Reduce Transparency is enabled.
    var matte: [Color] { dark ? [Color(white: 0.115), Color(white: 0.07), Color(white: 0.05)] : [Color(white: 0.995), Color(white: 0.955), Color(white: 0.915)] }

    @MainActor static var current: Theme { Theme(dark: AppSettings.shared.prefs.theme == .darkMatte, accentNS: Look.shared.accentNS) }
}

struct VisualEffectBlur: NSViewRepresentable {
    var dark: Bool
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        v.material = .hudWindow
        v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        v.material = dark ? .hudWindow : .popover
    }
}

@Observable @MainActor
final class Accessibility {
    static let shared = Accessibility()
    var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    @ObservationIgnored private var obs: NSObjectProtocol?
    private init() {
        obs = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Accessibility.shared.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            }
        }
    }
}

// MARK: - Notch-like shape: flush top with small outward "ears", continuous bottom corners.

struct IslandShape: Shape {
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
        let k: CGFloat = 0.552 // circle-ish bezier constant, then softened for continuity
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))
        // top-right ear
        p.addCurve(to: CGPoint(x: w - e, y: e), control1: CGPoint(x: w - e * k, y: 0), control2: CGPoint(x: w - e, y: e * (1 - k)))
        p.addLine(to: CGPoint(x: w - e, y: h - r))
        // bottom-right (continuous-style corner: longer tangents)
        p.addCurve(to: CGPoint(x: w - e - r, y: h), control1: CGPoint(x: w - e, y: h - r * 0.28), control2: CGPoint(x: w - e - r * 0.28, y: h))
        p.addLine(to: CGPoint(x: e + r, y: h))
        p.addCurve(to: CGPoint(x: e, y: h - r), control1: CGPoint(x: e + r * 0.28, y: h), control2: CGPoint(x: e, y: h - r * 0.28))
        p.addLine(to: CGPoint(x: e, y: e))
        p.addCurve(to: CGPoint(x: 0, y: 0), control1: CGPoint(x: e, y: e * (1 - k)), control2: CGPoint(x: e * k, y: 0))
        p.closeSubpath()
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

// MARK: - Root

struct IslandRootView: View {
    private let model = IslandModel.shared
    private let settings = AppSettings.shared

    private enum Face: Hashable { case closed, peek(UUID), expanded, permission(UUID), celebration(UUID) }

    private var face: Face {
        if let r = model.currentPermission { return .permission(r.id) }
        if let c = model.celebration { return .celebration(c.id) }
        if model.expanded { return .expanded }
        if let p = model.peek { return .peek(p.id) }
        return .closed
    }

    var body: some View {
        let theme = Theme.current
        let size = model.size
        let open = model.expanded || model.currentPermission != nil
        // MARK: feat/controls: shape comes from IslandGeometry (Notch | Pill), one place for every layer.
        let shape = IslandGeometry.outline(open: open, size: size)
        let ear = IslandGeometry.ear(open: open)
        let inset = IslandGeometry.topInset
        let glowTop = min(inset, GlowEdge.pad)
        let polish = settings.prefs.polish
        let look = Look.shared
        let palette = look.musicPalette
        let glow = GlowPalette.config(model: model, open: open, ear: shape.ear, radius: shape.radius)
            ?? GlowConfig(colors: GlowPalette.rainbow, intensity: 0, rotates: false, period: 10, pulse: nil, ear: shape.ear, radius: shape.radius)

        ZStack(alignment: .top) {
            // Edge glow (Core Animation; sits behind the island, only its outer half shows).
            GlowEdge(config: glow)
                .frame(width: size.width + GlowEdge.pad * 2, height: size.height + GlowEdge.pad + glowTop)
                .mask(GlowMask(size: size, outline: shape, topPad: glowTop,
                               strength: (ChromeAmbilight.shared.engaged || ChromeAmbilight.shared.simulating || model.celebration?.kind == .cinemaIntro)
                                   ? settings.prefs.glowStrength : .normal))
                .allowsHitTesting(false)
                .offset(y: -glowTop)

            // MARK: feat/system-media (satellite capsules beside the pill, snap zone strip below it)
            SatelliteLayer()
            SnapZoneStrip()

            ZStack(alignment: .top) {
                if Accessibility.shared.reduceTransparency {
                    // macOS "Reduce transparency" is on: respect it with a rich matte gradient.
                    LinearGradient(colors: theme.matte, startPoint: .top, endPoint: .bottom)
                        .opacity(open ? 1 : 0)
                } else {
                    VisualEffectBlur(dark: theme.dark)
                        .opacity(open ? 1 : 0)
                }
                Rectangle().fill(theme.pill)
                    .opacity(open ? (Accessibility.shared.reduceTransparency ? 0 : (theme.dark ? 0.38 : 0.42)) : 1)
                if open {
                    // Soft colour wash from the music (or accent when nothing plays).
                    ZStack {
                        RadialGradient(colors: [Color(nsColor: palette[0]).opacity(theme.dark ? 0.20 : 0.16), .clear],
                                       center: .topLeading, startRadius: 0, endRadius: 380)
                        RadialGradient(colors: [Color(nsColor: palette.count > 1 ? palette[1] : palette[0]).opacity(theme.dark ? 0.13 : 0.10), .clear],
                                       center: .bottomTrailing, startRadius: 0, endRadius: 360)
                    }
                    .animation(.easeInOut(duration: 0.8), value: look.paletteKey)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                if open && polish {
                    // Thin glassy top-edge highlight (1 px inside the clip).
                    shape.stroke(LinearGradient(colors: [Color.white.opacity(theme.dark ? 0.22 : 0.9), .clear],
                                                startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4)), lineWidth: 2)
                        .allowsHitTesting(false)
                }
                content(theme: theme, ear: ear)
                if !open { GuardDots() } // MARK: feat/system-media (camera / mic indicator)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)
            .overlay(shape.stroke(theme.dark ? Color.white.opacity(open ? 0.07 : 0) : Color.black.opacity(0.06), lineWidth: 0.5))
            .shadow(color: .black.opacity(open && polish ? 0.22 : 0), radius: 5, y: 2)
            .shadow(color: .black.opacity(open ? (polish ? 0.42 : 0.38) : (model.peek != nil ? 0.25 : 0)),
                    radius: open ? (polish ? 30 : 22) : 10, y: open ? (polish ? 16 : 10) : 4)
            .environment(\.colorScheme, theme.dark ? .dark : .light)
        }
        .modifier(ShakeEffect(progress: model.pillShake))
        .saturation(model.glowFlash == .deny && !open ? 0.2 : 1)
        .scaleEffect(model.hoveringClosed && polish && !open ? 1.045 : 1, anchor: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: model.hoveringClosed)
        .padding(.top, inset) // feat/controls: Pill height offset
        // MARK: wip/cinema-h: shape and offset changes morph with the island's spring (one
        // continuous outline), instead of jumping while content transitions are still running.
        .animation(IslandModel.openSpring, value: settings.prefs.islandStyle)
        .animation(IslandModel.openSpring, value: inset)
        .frame(width: IslandMetrics.window.width, height: IslandMetrics.window.height, alignment: .top)
    }

    @ViewBuilder
    private func content(theme: Theme, ear: CGFloat) -> some View {
        ZStack(alignment: .top) {
            switch face {
            case .closed:
                ClosedContent(theme: theme)
                    .frame(width: model.size.width, height: model.size.height)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            case .peek:
                if let p = model.peek {
                    PeekContent(peek: p, theme: theme)
                        .frame(width: model.size.width, height: model.size.height)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .top)).animation(.easeOut(duration: 0.25).delay(0.06)),
                            removal: .opacity.animation(.easeIn(duration: 0.1))))
                }
            case .expanded:
                ExpandedContent(theme: theme)
                    .frame(width: model.size.width, height: model.size.height)
                    // MARK: wip/cinema-h: on close the content goes out on its own fast curve
                    // (0.06 s), not the outline's spring, so full-size cards are never drawn
                    // inside a shrinking shape. A transition's own animation was overridden by
                    // the close spring, which kept the cards for ~0.1 s and cropped them.
                    .opacity(model.expanded ? 1 : 0)
                    .animation(model.expanded ? .easeOut(duration: 0.2) : .easeIn(duration: 0.06), value: model.expanded)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)).animation(.easeOut(duration: 0.28).delay(0.07)),
                        removal: .identity))
            case .celebration:
                if let c = model.celebration {
                    // Played inside the pill: the strip scene is uniformly scaled to fit.
                    let design = c.kind.size
                    let target = model.size
                    let k = min((target.width - 10) / design.width, target.height / design.height)
                    CelebrationPlayer(celebration: c, theme: theme, fixedTime: model.debugFixedTime)
                        .frame(width: design.width, height: design.height)
                        .scaleEffect(k)
                        .frame(width: target.width, height: target.height)
                        .clipShape(IslandGeometry.outline(open: false, size: target)) // feat/controls: follows the chosen shape
                        .contentShape(Rectangle())
                        .onTapGesture { if c.kind.dismissOnClick { model.endCelebration() } }
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.05)),
                            removal: .opacity.animation(.easeIn(duration: 0.15))))
                }
            case .permission:
                if let r = model.currentPermission {
                    PermissionView(request: r, theme: theme, queued: model.permissions.count)
                        .frame(width: IslandMetrics.permission.width, height: IslandMetrics.permission.height)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)).animation(.easeOut(duration: 0.28).delay(0.07)),
                            removal: .opacity.animation(.easeIn(duration: 0.12))))
                }
            }
        }
    }
}

// MARK: - Closed pill

struct ClosedContent: View {
    let theme: Theme
    private let np = NowPlaying.shared
    private let timer = FocusTimer.shared
    private let cinema = ChromeAmbilight.shared

    var body: some View {
        let p = AppSettings.shared.prefs
        let inCinema = cinema.videoContext && p.cinemaExtension && IslandContext.shared.cinemaAllowed
        let overlay = inCinema && (cinema.intermission || IslandModel.shared.hoverControls
            || cinema.titleCardUntil != nil || cinema.endsCardUntil != nil)
        ZStack {
            if inCinema && cinema.playing && p.cinemaInterior { InteriorLight().allowsHitTesting(false) }
            normalRow
                .opacity(overlay ? (IslandModel.shared.hoverControls || cinema.intermission ? 0.0 : 0.35) : 1)
            if fullEQ {
                // One full-width equaliser between the artwork and the right edge.
                Equaliser()
                    .padding(.leading, 44).padding(.trailing, 14).padding(.vertical, 4)
                    .opacity(overlay ? (IslandModel.shared.hoverControls || cinema.intermission ? 0 : 0.22) : 1)
                    .allowsHitTesting(false)
            }
            if inCinema { CinemaPillOverlay(theme: theme) }
            if IslandModel.shared.permissionWaiting {
                // Prompter running: a Claude approval waits as a small amber dot (click to answer).
                Circle().fill(Color(red: 1, green: 0.7, blue: 0.15)).frame(width: 7, height: 7)
                    .shadow(color: .orange.opacity(0.8), radius: 3)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(IslandModel.openSpring) { IslandModel.shared.revealPermissions = true } }
                    .help("Claude is waiting for approval. Click to answer")
            }
            if cinema.pausedDot && p.cinemaExtension {
                // Paused for over 30 min: a tiny reminder dot at the pill's edge (click to dismiss).
                // A small white pause glyph (distinct from the orange mic / green camera dots).
                Image(systemName: "pause.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 12)
                    .accessibilityLabel("A video is paused")
                    .onTapGesture { cinema.dismissIntermission() }
                    .help("A video is paused. Click to dismiss")
            }
            LongCommandPillBadge(theme: theme) // MARK: feat/claude-dev
        }
        .animation(.easeInOut(duration: 0.3), value: overlay)
    }

    static let chromeIcon: NSImage = {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: nil) ?? NSImage()
    }()

    private var fullEQ: Bool {
        let p = AppSettings.shared.prefs
        return cinema.videoContext && p.cinemaExtension && p.cinemaWave && p.equaliserStyle == .fullWidth && IslandContext.shared.cinemaAllowed
    }

    private var normalRow: some View {
        HStack(spacing: 0) {
            if let m = FootballService.shared.pillMatch {
                Badge(team: m.home, size: 16).padding(.leading, 14)
                Text("\(m.home.abbr) \(m.homeScore)–\(m.awayScore) \(m.away.abbr)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(theme.primary)
                    .padding(.leading, 6)
                Badge(team: m.away, size: 16).padding(.leading, 6)
                Spacer(minLength: 0)
                Text(m.statusName == "STATUS_HALFTIME" ? "HT" : m.clock)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Color(red: 1, green: 0.3, blue: 0.3))
                    .padding(.trailing, 15)
            } else if np.hasMedia {
                if CharacterEngine.shared.showing { // MARK: wip/character (the character takes the artwork's place)
                    CharacterPillSlot(theme: theme)
                } else {
                    ArtworkView(image: np.artwork, size: 20, corner: 5)
                        .padding(.leading, 14)
                }
                Spacer(minLength: 0)
                AudioBars(playing: np.isPlaying || (np.bundleID == "com.google.Chrome" && ChromeAmbilight.shared.playing),
                          color: AppSettings.shared.prefs.musicColors ? Look.shared.musicPrimary : theme.primary)
                    .frame(width: 20, height: 14)
                    .opacity(fullEQ ? 0 : 1)
                    .padding(.trailing, 15)
            } else if cinema.videoContext && AppSettings.shared.prefs.cinemaExtension {
                // A video plays in Chrome but macOS has no media session for it (e.g. archive.org):
                // still show the browser icon and bars, never an empty pill.
                Image(nsImage: Self.chromeIcon).resizable().interpolation(.high).frame(width: 20, height: 20)
                    .padding(.leading, 14)
                Spacer(minLength: 0)
                AudioBars(playing: cinema.playing, color: Look.shared.musicPrimary)
                    .frame(width: 20, height: 14)
                    .opacity(fullEQ ? 0 : 1)
                    .padding(.trailing, 15)
            } else if timer.running {
                Image(systemName: "timer").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent)
                    .padding(.leading, 16)
                Spacer(minLength: 0)
                Text(timer.label).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(theme.accent)
                    .padding(.trailing, 16)
            } else if AppSettings.shared.prefs.focusScoreInPill && AppSettings.shared.prefs.focusMatch {
                Image(systemName: "sportscourt").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.accent).padding(.leading, 16)
                Spacer(minLength: 0)
                Text(FocusMatch.shared.scoreLine).font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(theme.primary)
                    .padding(.trailing, 16)
            } else if CharacterEngine.shared.showing { // MARK: wip/character
                CharacterPillSlot(theme: theme)
                Spacer(minLength: 0)
                CharacterPillIndicator().padding(.trailing, 14)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 1)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.3), Color(white: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

extension NSImage {
    /// Average colour, lifted so it reads on black. Computed once per image.
    var accentColor: Color {
        if let c = objc_getAssociatedObject(self, &accentKey) as? NSColor { return Color(nsColor: c) }
        var px = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        var c = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        c = NSColor(hue: h, saturation: min(s * 1.2, 0.85), brightness: max(b, 0.8), alpha: 1)
        objc_setAssociatedObject(self, &accentKey, c, .OBJC_ASSOCIATION_RETAIN)
        return Color(nsColor: c)
    }
}
nonisolated(unsafe) private var accentKey: UInt8 = 0

// MARK: - Audio bars: Core Animation driven, so the app process does no per-frame work.

struct AudioBars: NSViewRepresentable {
    var playing: Bool
    var color: Color

    func makeNSView(context: Context) -> BarsView { BarsView() }
    func updateNSView(_ v: BarsView, context: Context) {
        v.setColor(NSColor(color))
        v.setPlaying(playing)
    }

    /// The small equaliser on the right of the pill: 5 bars (bass, low-mid, mid, high-mid,
    /// treble) driven by the real spectrum when there is one. Heights animate (rounded caps stay
    /// round) and the render server tweens at up to 60 fps between ~24 targets a second.
    final class BarsView: NSView {
        static let count = 5
        private var bars: [CALayer] = []
        private var isPlaying: Bool?
        private var shown = [CGFloat](repeating: 0.2, count: BarsView.count)
        private static let rate = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for _ in 0..<Self.count {
                let l = CALayer()
                l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer?.addSublayer(l)
                bars.append(l)
            }
        }
        required init?(coder: NSCoder) { fatalError() }

        private var w: CGFloat { 3 }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let gap = (bounds.width - CGFloat(Self.count) * w) / CGFloat(Self.count - 1)
            for (i, l) in bars.enumerated() {
                l.bounds = CGRect(x: 0, y: 0, width: w, height: max(w, bounds.height * shown[i]))
                l.position = CGPoint(x: (CGFloat(i) * (w + gap) + w / 2).rounded() + 0.25, y: bounds.midY)
                l.cornerRadius = w / 2
            }
            CATransaction.commit()
        }
        func setColor(_ c: NSColor) { bars.forEach { $0.backgroundColor = c.cgColor } }

        private var live = false

        private func setHeight(_ i: Int, _ v: CGFloat, duration: CFTimeInterval) {
            let l = bars[i]
            let h = max(w, bounds.height * v)
            let from = (l.presentation() ?? l).bounds.size.height
            shown[i] = v
            CATransaction.begin(); CATransaction.setDisableActions(true)
            l.bounds.size.height = h
            CATransaction.commit()
            guard duration > 0 else { return }
            let a = CABasicAnimation(keyPath: "bounds.size.height")
            a.fromValue = from; a.toValue = h; a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            a.preferredFrameRateRange = Self.rate
            l.add(a, forKey: "h")
        }

        /// Real audio levels (0...1, one per bar); nil = no live audio.
        func setLevels(_ levels: [Float]?) {
            guard let levels, levels.count >= Self.count else {
                if live { live = false; isPlaying.map { p in isPlaying = nil; setPlaying(p) } }
                return
            }
            if !live {
                live = true
                bars.forEach { $0.removeAnimation(forKey: "breathe") }
            }
            let d = 1.15 / ClaudeConnection.maxRate
            for i in 0..<Self.count {
                let v = CGFloat(0.12 + 0.88 * min(max(levels[i], 0), 1))   // silence: thin baseline
                if abs(v - shown[i]) < 0.02 { continue }
                setHeight(i, v, duration: d)
            }
        }

        func setPlaying(_ p: Bool) {
            if window != nil { MainActor.assumeIsolated { AudioBarsRegistry.view = self } }
            guard p != isPlaying else { return }
            isPlaying = p
            if live && p { return } // real levels drive the bars
            for (i, l) in bars.enumerated() {
                l.removeAnimation(forKey: "breathe"); l.removeAnimation(forKey: "h")
                if p {
                    // No live audio (e.g. Music or Spotify): a calm, slow breathing, never fake bouncing.
                    let a = CABasicAnimation(keyPath: "bounds.size.height")
                    a.fromValue = max(w, bounds.height * 0.3)
                    a.toValue = max(w, bounds.height * 0.6)
                    a.duration = 1.4 + Double(i) * 0.15
                    a.autoreverses = true
                    a.repeatCount = .infinity
                    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    a.beginTime = CACurrentMediaTime() + Double(i) * 0.2
                    a.preferredFrameRateRange = CAQuiet.rate
                    l.add(a, forKey: "breathe")
                    setHeight(i, 0.45, duration: 0)
                } else {
                    setHeight(i, 0.12, duration: 0.25)
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { MainActor.assumeIsolated { AudioBarsRegistry.view = self } }
        }
    }
}

// MARK: - Peek

struct PeekContent: View {
    let peek: Peek
    let theme: Theme

    /// Peeks live inside the pill: icon, title and value on one line.
    var body: some View {
        HStack(spacing: 6) {
            if let icon = peek.icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else if let s = peek.symbol {
                Image(systemName: s)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(peek.tint == .white ? theme.primary : peek.tint)
                    .symbolRenderingMode(.hierarchical)
            }
            Text(peek.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.primary).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 4)
            if let title = peek.actionTitle {
                Button {
                    peek.action?()
                    IslandModel.shared.dismissPeek()
                } label: {
                    Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 8).frame(height: 18).background(Capsule().fill(theme.accent))
                }
                .buttonStyle(PressScaleStyle())
            } else if let s = peek.subtitle {
                Text(s).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    // Standard layout: [icon] what happened (white) ... who / which (status colour, right).
                    .foregroundStyle(peek.tint == .white ? theme.accent : peek.tint).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 1)
    }
}


// MARK: - Cinema overlays inside the closed pill (never changes its size)

struct CinemaPillOverlay: View {
    let theme: Theme
    private let cinema = ChromeAmbilight.shared
    private let model = IslandModel.shared

    var body: some View {
        let p = AppSettings.shared.prefs
        ZStack {
            if cinema.intermission {
                intermission
            } else if model.hoverControls && p.cinemaHoverControls {
                controls
            } else if cinema.titleCardUntil != nil, p.cinemaTitle, !cinema.title.isEmpty {
                Text(cinema.title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold, design: .default))
                    .tracking(2.2)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 44)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if cinema.endsCardUntil != nil, let end = cinema.endsAt {
                Text("Ends \(end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .transition(.opacity)
            }
            // Progress line along the bottom edge.
            if p.cinemaProgress, let prog = cinema.progress, !cinema.intermission {
                GeometryReader { g in
                    let inset: CGFloat = 16
                    let w = (g.size.width - inset * 2) * prog
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(width: max(2, w), height: 1.5)
                        .shadow(color: .white.opacity(0.7), radius: 2)
                        .position(x: inset + w / 2, y: g.size.height - 2.5)
                        // No SwiftUI animation here: a 1 s step on a 1.5 pt line is invisible, and an
                        // animation every second would keep a display link running for the whole video.
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var intermission: some View {
        // A takeover of the whole pill: a big popcorn bucket and the paused time. The text only
        // changes once a minute; a piece pops every ~8 s (a short one-off animation).
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let mins = max(0, Int(ctx.date.timeIntervalSince(cinema.pausedAt ?? ctx.date) / 60))
            HStack(spacing: 8) {
                PopcornBucket().frame(width: 26, height: 30).offset(y: -1)
                if model.hoverControls {
                    // Hover: resume (plays and brings the tab to the front) or dismiss the reminder.
                    Button { cinema.resumeFromIntermission(focusTab: true) } label: {
                        Label("Resume", systemImage: "play.fill").font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 9).frame(height: 20).background(Capsule().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain).foregroundStyle(.white).help("Play the video and show its tab")
                    Button { cinema.dismissIntermission() } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20).background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.85)).help("Dismiss")
                } else {
                    Text("Intermission · paused \(mins == 0 ? "just now" : "\(mins) min")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
        }
        .transition(.opacity)
    }

    private var controls: some View {
        HStack(spacing: 4) {
            ctl("gobackward.10", "Back 10 s") { cinema.command("back") }
            ctl(cinema.playing ? "pause.fill" : "play.fill", cinema.playing ? "Pause" : "Play") { cinema.command("toggle") }
            ctl("goforward.10", "Forward 10 s") { cinema.command("forward") }
            ctl("pip.enter", "Picture in picture") { cinema.command("pip") }
            ctl("arrow.up.left.and.arrow.down.right", "Full screen") { cinema.command("fullscreen") }
            if let end = cinema.endsAt {
                Text(end.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.leading, 2)
            }
        }
        .transition(.opacity)
    }

    private func ctl(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .help(help)
    }
}


// MARK: - Intermission popcorn (drawn, not a symbol)

struct PopcornBucket: View {
    var body: some View {
        ZStack {
            Canvas { ctx, size in Self.draw(&ctx, size) }
            if !Power.shared.saving {   // battery saver: no popping
            TimelineView(.periodic(from: .now, by: 8)) { tl in
                let n = Int(tl.date.timeIntervalSinceReferenceDate / 8)
                PoppedPiece(seed: n)
                    .keyframeAnimator(initialValue: 0.0, trigger: n) { v, p in
                        let dx = CGFloat((n % 3) - 1) * 6 * CGFloat(p)
                        let dy = -12 * CGFloat(sin(p * Double.pi)) + 2
                        return v.offset(x: dx, y: dy)
                            .rotationEffect(.degrees(p * 160))
                            .opacity(p < 0.92 ? 1.0 : (1.0 - p) * 12.0)
                    } keyframes: { _ in
                        LinearKeyframe(0, duration: 0.01)
                        CubicKeyframe(1, duration: 0.75)
                    }
                    .offset(y: -9)
            }
            }
        }
    }

    static let cream = Color(red: 1, green: 0.95, blue: 0.82)
    static let butter = Color(red: 1, green: 0.84, blue: 0.42)

    static func draw(_ ctx: inout GraphicsContext, _ s: CGSize) {
        let w = s.width, h = s.height
        let top = h * 0.42, bottom = h
        let topInset = w * 0.06, bottomInset = w * 0.22
        // Popcorn heaped over the rim.
        let puffs: [(CGFloat, CGFloat, CGFloat)] = [
            (0.22, 0.40, 0.17), (0.40, 0.30, 0.19), (0.60, 0.30, 0.18), (0.78, 0.40, 0.17),
            (0.32, 0.17, 0.16), (0.52, 0.12, 0.17), (0.70, 0.20, 0.15), (0.14, 0.30, 0.12), (0.88, 0.30, 0.12)]
        for (i, (x, y, r)) in puffs.enumerated() {
            let rr = r * w
            let rect = CGRect(x: x * w - rr, y: y * h - rr, width: rr * 2, height: rr * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(i % 3 == 1 ? butter : cream))
            ctx.fill(Path(ellipseIn: rect.insetBy(dx: rr * 0.45, dy: rr * 0.45).offsetBy(dx: -rr * 0.2, dy: -rr * 0.2)),
                     with: .color(.white.opacity(0.7)))
        }
        // Bucket: a tapered tub with red and white stripes.
        var tub = Path()
        tub.move(to: CGPoint(x: topInset, y: top))
        tub.addLine(to: CGPoint(x: w - topInset, y: top))
        tub.addLine(to: CGPoint(x: w - bottomInset, y: bottom))
        tub.addLine(to: CGPoint(x: bottomInset, y: bottom))
        tub.closeSubpath()
        ctx.fill(tub, with: .color(.white))
        ctx.drawLayer { l in
            l.clip(to: tub)
            let stripes = 5
            for k in 0..<stripes where k % 2 == 0 {
                let x0 = CGFloat(k) / CGFloat(stripes) * w, x1 = CGFloat(k + 1) / CGFloat(stripes) * w
                var p = Path()
                p.move(to: CGPoint(x: x0, y: top)); p.addLine(to: CGPoint(x: x1, y: top))
                p.addLine(to: CGPoint(x: w / 2 + (x1 - w / 2) * 0.7, y: bottom)); p.addLine(to: CGPoint(x: w / 2 + (x0 - w / 2) * 0.7, y: bottom))
                p.closeSubpath()
                l.fill(p, with: .color(Color(red: 0.9, green: 0.12, blue: 0.16)))
            }
        }
        // Rim.
        ctx.fill(Path(roundedRect: CGRect(x: topInset - 1, y: top - 1.5, width: w - 2 * topInset + 2, height: 3), cornerRadius: 1.5),
                 with: .color(Color(red: 0.95, green: 0.2, blue: 0.22)))
    }
}

private struct PoppedPiece: View {
    let seed: Int
    var body: some View {
        Circle().fill(seed % 2 == 0 ? PopcornBucket.cream : PopcornBucket.butter).frame(width: 6, height: 6)
            .overlay(Circle().fill(.white.opacity(0.7)).frame(width: 2.5, height: 2.5).offset(x: -1, y: -1))
    }
}
