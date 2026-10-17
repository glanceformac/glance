import AppKit
import SwiftUI

// MARK: - Kinds

enum CelebrationKind: Equatable {
    case teamGoal(GoalEvent)
    case claudeDone(project: String, detail: String)
    case commit(title: String, repo: String, message: String)
    case deployed(title: String, project: String)
    case redCard(title: String, line: String)
    case prMerged(repo: String, title: String)
    case taskTicked(done: Int, left: Int)
    case whistle(fullTime: Bool, title: String, detail: String)
    case kickoff(title: String, joinURL: URL?)
    case crowdWave(title: String, score: String)
    case cinemaIntro
    case cinemaOutro

    /// Played by Core Animation layers (CinemaIntroCA), not the SwiftUI scene renderer.
    var isCinemaCA: Bool { self == .cinemaIntro || self == .cinemaOutro }

    var duration: Double {
        switch self {
        case .teamGoal: 5.6
        case .claudeDone: 2.6
        case .commit: 2.8
        case .deployed: 2.8
        case .redCard: 2.6
        case .prMerged: 2.8
        case .taskTicked: 1.9
        case .whistle: 2.6
        case .kickoff(_, let url): url == nil ? 3.2 : 8
        case .crowdWave: 2.8
        case .cinemaIntro: IntroH.duration
        case .cinemaOutro: IntroH.outroDuration
        }
    }

    /// Slim score-bug strip grown out of the pill.
    var size: CGSize {
        switch self {
        case .teamGoal: CGSize(width: 420, height: 44)
        case .kickoff(_, let url): CGSize(width: url == nil ? 380 : 420, height: 40)
        case .cinemaIntro, .cinemaOutro: IslandMetrics.closed   // drawn at the pill's own size: no scaling
        default: CGSize(width: 400, height: 40)
        }
    }
    /// The goal celebration briefly grows taller at its peak.
    var peakHeight: CGFloat { size.height }

    /// Glow colours while playing.
    var glow: [NSColor] {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        switch self {
        case .teamGoal(let g): let tc = g.team.displayColor; return [tc, c(1, 0.78, 0.25), tc, c(1, 1, 1)]
        case .claudeDone: return [c(0.25, 0.88, 0.45), c(0.6, 1, 0.7)]
        case .commit: return [c(0.3, 0.9, 0.7), c(0.45, 0.65, 1), c(1, 0.8, 0.3)]
        case .deployed: return [c(0.75, 0.9, 1), c(1, 1, 1), c(0.35, 0.6, 1)]
        case .redCard: return [c(1, 0.2, 0.2), c(0.7, 0, 0)]
        case .prMerged: return [c(1, 0.8, 0.25), c(1, 0.95, 0.6)]
        case .taskTicked: return [c(0.3, 0.9, 0.5), c(1, 1, 1)]
        case .whistle: return [c(1, 1, 1), c(0.7, 0.75, 0.8)]
        case .kickoff: return [c(0.3, 0.85, 0.4), c(1, 1, 1)]
        case .crowdWave: return [c(1, 0.5, 0.3), c(0.4, 0.6, 1), c(1, 0.85, 0.3)]
        case .cinemaIntro, .cinemaOutro: return [c(1, 0.2, 0.3), c(1, 0.6, 0.1), c(0.3, 0.8, 1), c(0.6, 0.3, 1)]
        }
    }

    var dismissOnClick: Bool { if case .teamGoal = self { return false }; if case .kickoff = self { return false }; return true }

    /// Demo instances for Settings › Football › Preview.
    static let previews: [(String, CelebrationKind)] = [
        ("Goal", .teamGoal(.demo)),
        ("Claude done", .claudeDone(project: "island", detail: "2 files changed · 3m 12s")),
        ("Git commit / push", .commit(title: "COMMIT", repo: "glanceformac/glance", message: "Add football celebrations")),
        ("Push / deploy", .deployed(title: "DEPLOYED", project: "my-app")),
        ("Red card (failure)", .redCard(title: "DEPLOY FAILED", line: "Error: Command \"npm run build\" exited with 1")),
        ("PR merged", .prMerged(repo: "island", title: "#42 Football mode")),
        ("Task ticked", .taskTicked(done: 4, left: 1)),
        ("Focus half-time", .whistle(fullTime: false, title: "HALF-TIME", detail: "Focus 1–0 Distractions")),
        ("Focus full-time", .whistle(fullTime: true, title: "FULL-TIME", detail: "Focus 2–0 Distractions")),
        ("Meeting kick-off", .kickoff(title: "Design review", joinURL: URL(string: "https://meet.google.com/abc-defg-hij"))),
        ("Timer done / end of day", .crowdWave(title: "FULL-TIME", score: "You 4–1 To-do")),
        ("Cinema intro", .cinemaIntro),
        ("Cinema outro", .cinemaOutro),
    ]
}

struct Celebration: Identifiable {
    let id = UUID()
    let kind: CelebrationKind
    var started = Date()
}

// MARK: - Timing helpers (every frame is a pure function of t)

@inline(__always) func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
/// Progress of t through [a, b], 0...1.
@inline(__always) func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp01((t - a) / (b - a)) }
@inline(__always) func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
@inline(__always) func easeIn(_ x: Double) -> Double { x * x * x }
@inline(__always) func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
/// Springy overshoot that settles at 1.
@inline(__always) func springy(_ x: Double) -> Double { x <= 0 ? 0 : (x >= 1 ? 1 : 1 - exp(-6 * x) * cos(11 * x)) }
@inline(__always) func lerp(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }
/// Deterministic pseudo-random 0...1.
@inline(__always) func rnd(_ i: Int, _ salt: Int = 0) -> Double {
    var x = UInt64(truncatingIfNeeded: i &* 0x9E3779B1 &+ salt &* 0x85EBCA77 &+ 0x165667B1)
    x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33; x = x &* 0xc4ceb9fe1a85ec53; x ^= x >> 33
    return Double(x % 10_000) / 10_000
}

// MARK: - Player

struct CelebrationPlayer: View {
    let celebration: Celebration
    let theme: Theme
    /// Fixed time for snapshots; nil = live playback.
    var fixedTime: Double? = nil

    var body: some View {
        if celebration.kind.isCinemaCA {
            // Core Animation intro/outro: built once inside the pill, played by the render server.
            let s = celebration.kind.size
            CinemaIntroCA(started: celebration.started, fixedTime: fixedTime, size: s, outro: celebration.kind == .cinemaOutro)
                .frame(width: s.width, height: s.height, alignment: .top)
        } else if let t = fixedTime {
            frame(t)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: false)) { ctx in
                frame(ctx.date.timeIntervalSince(celebration.started))
            }
        }
    }

    @ViewBuilder
    private func frame(_ t: Double) -> some View {
        let size = celebration.kind.size
        Group {
            switch celebration.kind {
            case .teamGoal(let g): GoalScene(goal: g, t: t)
            case .claudeDone(let p, let d): DoneScene(project: p, detail: d, t: t)
            case .commit(let title, let repo, let msg): CommitScene(title: title, repo: repo, message: msg, t: t)
            case .deployed(let title, let p): DeployScene(title: title, project: p, t: t)
            case .redCard(let title, let line): RedCardScene(title: title, line: line, t: t)
            case .prMerged(let repo, let title): TrophyScene(repo: repo, title: title, t: t)
            case .taskTicked(let d, let l): FlapScene(done: d, left: l, t: t)
            case .whistle(let full, let title, let detail): WhistleScene(fullTime: full, title: title, detail: detail, t: t)
            case .kickoff(let title, let url): KickoffScene(title: title, joinURL: url, t: t)
            case .crowdWave(let title, let score): CrowdScene(title: title, score: score, t: t)
            case .cinemaIntro, .cinemaOutro: Color.clear   // drawn by CinemaIntroCA
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Shared pieces

struct Badge: View {
    let team: TeamInfo
    let size: CGFloat
    private let cache = BadgeCache.shared
    var body: some View {
        ZStack {
            // Light backing so dark crests (e.g. navy) read on dark bars.
            Circle().fill(Color.white.opacity(0.9)).frame(width: size * 0.92, height: size * 0.92).blur(radius: size * 0.08)
                .opacity(cache.images[team.id] == nil ? 0 : 1)
            content
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var content: some View {
        Group {
            if let img = cache.image(for: team) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    Circle().fill(Color(nsColor: team.nsColor ?? .darkGray))
                    Text(team.abbr).font(.system(size: size * 0.3, weight: .heavy)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct SoccerBall: View {
    let size: CGFloat
    var spin: Double = 0
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [.white, Color(white: 0.82)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.7))
            ForEach(0..<5, id: \.self) { i in
                let a = Double(i) / 5 * 2 * .pi
                Circle().fill(Color(white: 0.12))
                    .frame(width: size * 0.22, height: size * 0.22)
                    .offset(x: cos(a) * size * 0.3, y: sin(a) * size * 0.3)
            }
            Circle().fill(Color(white: 0.12)).frame(width: size * 0.26, height: size * 0.26)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .rotationEffect(.radians(spin))
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }
}

/// Big bold headline word.
struct Headline: View {
    let text: String
    var size: CGFloat = 40
    var color: Color = .white
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .black, design: .default).italic())
            .tracking(1)
            .foregroundStyle(color)
            .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
            .fixedSize()
    }
}

/// Smoke puffs, embers, sparks: drawn deterministically in a Canvas.
enum Particles {
    static func smoke(_ ctx: inout GraphicsContext, at p: CGPoint, age: Double, seed: Int, scale: CGFloat = 1) {
        guard age > 0, age < 1.6 else { return }
        let r = CGFloat(4 + age * 14) * scale
        let drift = CGPoint(x: p.x + CGFloat(rnd(seed, 1) - 0.5) * 18 * CGFloat(age), y: p.y - CGFloat(age) * 16 * scale)
        let a = (1 - age / 1.6) * 0.45
        ctx.fill(Path(ellipseIn: CGRect(x: drift.x - r, y: drift.y - r, width: r * 2, height: r * 2)),
                 with: .color(Color(white: 0.55 + rnd(seed, 2) * 0.2).opacity(a)))
    }

    static func embers(_ ctx: inout GraphicsContext, size: CGSize, t: Double, from: Double, to: Double, count: Int = 46) {
        for i in 0..<count {
            let start = from + rnd(i, 7) * (to - from) * 0.6
            let age = t - start
            guard age > 0, age < 1.4 else { continue }
            let x = CGFloat(rnd(i, 3)) * size.width + CGFloat(sin(age * 6 + Double(i))) * 6
            let y = size.height - CGFloat(age) * CGFloat(30 + rnd(i, 4) * 50)
            let r = CGFloat(1 + rnd(i, 5) * 1.8)
            let flick = 0.6 + 0.4 * sin(age * 30 + Double(i))
            let col = rnd(i, 6) > 0.5 ? Color(red: 1, green: 0.55, blue: 0.1) : Color(red: 1, green: 0.85, blue: 0.3)
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(col.opacity((1 - age / 1.4) * flick)))
        }
    }

    static func confetti(_ ctx: inout GraphicsContext, origin: CGPoint, t: Double, count: Int = 36) {
        let colors: [Color] = [.yellow, .pink, .mint, .orange, .cyan, .white, .purple]
        for i in 0..<count {
            let age = t
            guard age > 0, age < 1.4 else { continue }
            let ang = rnd(i, 1) * 2 * .pi
            let speed = 60 + rnd(i, 2) * 140
            let x = origin.x + CGFloat(cos(ang) * speed * age)
            let y = origin.y + CGFloat(sin(ang) * speed * age * 0.6 + 90 * age * age)
            var c = ctx
            c.translateBy(x: x, y: y)
            c.rotate(by: .radians(age * 12 * (rnd(i, 3) - 0.5)))
            c.fill(Path(CGRect(x: -2.5, y: -1.5, width: 5, height: 3)), with: .color(colors[i % colors.count].opacity(1 - age / 1.4)))
        }
    }

    static func twinkles(_ ctx: inout GraphicsContext, size: CGSize, t: Double, from: Double, color: Color, count: Int = 18) {
        for i in 0..<count {
            let start = from + rnd(i, 9) * 1.4
            let age = t - start
            guard age > 0, age < 0.7 else { continue }
            let x = CGFloat(rnd(i, 1)) * size.width, y = CGFloat(rnd(i, 2)) * size.height
            let s = CGFloat(sin(age / 0.7 * .pi)) * CGFloat(4 + rnd(i, 3) * 5)
            var p = Path()
            p.move(to: CGPoint(x: x, y: y - s)); p.addLine(to: CGPoint(x: x + s * 0.25, y: y - s * 0.25))
            p.addLine(to: CGPoint(x: x + s, y: y)); p.addLine(to: CGPoint(x: x + s * 0.25, y: y + s * 0.25))
            p.addLine(to: CGPoint(x: x, y: y + s)); p.addLine(to: CGPoint(x: x - s * 0.25, y: y + s * 0.25))
            p.addLine(to: CGPoint(x: x - s, y: y)); p.addLine(to: CGPoint(x: x - s * 0.25, y: y - s * 0.25))
            p.closeSubpath()
            ctx.fill(p, with: .color(color))
        }
    }
}

// MARK: - Opponent goal: grey shake + slow deflate of the closed pill

struct ShakeEffect: GeometryEffect {
    var progress: CGFloat // animates 0 -> 1 per shake
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let p = progress.truncatingRemainder(dividingBy: 1)
        guard progress > 0, p > 0 else { return ProjectionTransform(.identity) }
        let dx = sin(p * .pi * 8) * 7 * (1 - p)
        let deflate = 1 - 0.1 * sin(p * .pi)
        let t = CGAffineTransform(translationX: dx + size.width * (1 - deflate) / 2, y: 0).scaledBy(x: deflate, y: deflate)
        return ProjectionTransform(t)
    }
}
