import AppKit
import SwiftUI

// Slim "TV score bug" versions of every celebration. Each frame is a pure function of t.
// Strip: about 400 x 40 pt (goal 420 x 44, growing to 58 at the peak).

private let stripH: CGFloat = 40

/// 2D card flip (no perspective singularity): squashes to the edge and swaps faces.
struct FlipCard<Front: View, Back: View>: View {
    let angle: Double // degrees, 0 = front, 180 = back
    @ViewBuilder let front: () -> Front
    @ViewBuilder let back: () -> Back
    var body: some View {
        let a = angle.truncatingRemainder(dividingBy: 360)
        let showBack = a > 90 && a < 270
        let sx = max(0.02, abs(cos(a * .pi / 180)))
        ZStack { if showBack { back() } else { front() } }
            .scaleEffect(x: sx, y: 1)
    }
}

// MARK: - Shot launcher (vector, pointing left): a ball with speed lines in the team colour

struct ShotLauncher: View {
    let tint: Color
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(tint.opacity(0.9 - Double(i) * 0.2))
                    .frame(width: CGFloat(12 - i * 2), height: 2)
                    .offset(x: 9 + CGFloat(i) * 1.5, y: CGFloat(i - 1) * 4)
            }
            SoccerBall(size: 13)
                .shadow(color: tint.opacity(0.8), radius: 3)
                .offset(x: -4)
        }
        .frame(width: 30, height: 22)
    }
}

// MARK: - 1. Goal (hero)

struct GoalScene: View {
    let goal: GoalEvent
    let t: Double
    private let W: CGFloat = 420, H: CGFloat = 58
    private let midY: CGFloat = 22
    private var opp: TeamInfo { goal.opponent }
    private var us: TeamInfo { goal.team }
    private var usColor: Color { Color(nsColor: goal.team.displayColor) }

    var body: some View {
        let cx = W / 2
        let wipe = easeOut(seg(t, 0.35, 0.8))
        let flipIn = seg(t, 0.8, 1.2)
        let flipOut = seg(t, 4.6, 5.0)
        let oppIn = springy(seg(t, 1.2, 1.6))
        let launcherOut = easeOut(seg(t, 1.6, 2.05))
        let backOff = easeOut(seg(t, 1.75, 2.1))
        let fire = seg(t, 2.1, 2.45)
        let impact = t >= 2.45
        let goalIn = springy(seg(t, 2.55, 3.0))
        let flashing = t >= 3.1 && t < 4.4
        let flashTeam = flashing && Int((t - 3.1) / 0.14) % 2 == 0
        let scriptIn = seg(t, 3.25, 3.7)
        let sceneOut = 1 - seg(t, 4.4, 4.7)
        let dim = seg(t, 2.1, 2.4) * (1 - seg(t, 4.4, 4.7))
        let barVisible = clamp01(1 - seg(t, 0.85, 1.1) + seg(t, 4.75, 5.0))
        let updated = t >= 5.05
        let bump = 1 + 0.35 * sin(seg(t, 5.05, 5.35) * .pi)
        // Crest moves from the centre into the O of GOAL and back.
        let crestX = cx - 24 + CGFloat(goalIn) * 0 - (t >= 4.4 ? 0 : 0)
        let crestHome = t >= 4.7 ? cx : (t < 2.55 ? cx : crestX)
        let oppX = cx - 64 - CGFloat(backOff) * 30 - CGFloat(seg(t, 2.55, 2.9)) * 92
        let target = CGPoint(x: oppX, y: midY)
        let muzzle = CGPoint(x: cx - 26 - CGFloat(launcherOut) * 12, y: midY - 1)

        ZStack(alignment: .topLeading) {
            // Halves: opponent colours left, the followed team's colour right.
            Rectangle().fill(Color.black)
            Rectangle().fill(LinearGradient(colors: [.black, Color(nsColor: opp.nsColor ?? NSColor(srgbRed: 0.07, green: 0.13, blue: 0.34, alpha: 1))],
                                            startPoint: .leading, endPoint: .trailing))
                .frame(width: W / 2 * CGFloat(wipe), height: H)
            Rectangle().fill(LinearGradient(colors: [Color(nsColor: goal.team.displayColor.blended(withFraction: 0.45, of: .black) ?? goal.team.displayColor), .black], startPoint: .leading, endPoint: .trailing))
                .frame(width: W / 2 * CGFloat(wipe), height: H)
                .offset(x: W / 2)
            Rectangle().fill(Color.black.opacity(0.3 * dim))

            scoreBar(updated: updated, bump: bump)
                .frame(width: W, height: 26)
                .position(x: cx, y: midY)
                .opacity(barVisible)

            Canvas { ctx, size in
                if t >= 2.1 && t < 4.4 {
                    for i in 0..<12 {
                        let s = Double(i) / 11
                        let launched = 2.1 + s * 0.35
                        guard t > launched else { continue }
                        let p = CGPoint(x: muzzle.x + (target.x - muzzle.x) * CGFloat(s), y: muzzle.y + (target.y - muzzle.y) * CGFloat(s) - CGFloat(sin(s * .pi)) * 6)
                        Particles.smoke(&ctx, at: p, age: (t - launched) * 0.9, seed: i, scale: 0.45)
                    }
                }
                if t >= 2.45 && t < 3.05 && Int(t * 24) % 2 == 0 {
                    for k in 0..<5 {
                        var path = Path()
                        let ang = rnd(k, Int(t * 24)) * 2 * .pi
                        var p = CGPoint(x: target.x + CGFloat(cos(ang)) * 20, y: target.y + CGFloat(sin(ang)) * 15)
                        path.move(to: p)
                        for j in 1...3 {
                            let f = CGFloat(j) / 3
                            p = CGPoint(x: p.x + (target.x - p.x) * f + CGFloat(rnd(k * 9 + j, 3) - 0.5) * 6,
                                        y: p.y + (target.y - p.y) * f + CGFloat(rnd(k * 9 + j, 4) - 0.5) * 6)
                            path.addLine(to: p)
                        }
                        ctx.stroke(path, with: .color(Color(red: 1, green: 0.95, blue: 0.5)), lineWidth: 1.4)
                    }
                }
                if t >= 2.6 && t < 4.6 {
                    for i in 0..<8 {
                        let born = 2.6 + Double(i) * 0.2
                        Particles.smoke(&ctx, at: CGPoint(x: target.x + CGFloat(rnd(i, 8) - 0.5) * 8, y: target.y - 6), age: (t - born) * 0.8, seed: 50 + i, scale: 0.4)
                    }
                }
                Particles.embers(&ctx, size: size, t: t, from: 3.0, to: 4.7, count: 34)
            }
            .frame(width: W, height: H)
            .opacity(sceneOut)
            .allowsHitTesting(false)

            // Opponent badge: appears, backs off, gets blackened.
            Badge(team: opp, size: 22)
                .saturation(impact ? 0 : 1)
                .brightness(impact ? -0.5 : 0)
                .scaleEffect(CGFloat(oppIn))
                .offset(x: impact && t < 2.7 ? CGFloat(sin(t * 80)) * 1.5 : 0)
                .position(x: oppX, y: midY)
                .opacity(oppIn > 0 ? sceneOut : 0)

            ShotLauncher(tint: usColor)
                .position(x: cx - 14 - CGFloat(launcherOut) * 12 + (t > 2.1 && t < 2.25 ? 3 : 0), y: midY + 1)
                .opacity(launcherOut > 0 ? sceneOut * (1 - seg(t, 2.55, 2.8)) : 0)

            if t >= 2.1 && t < 2.5 {
                let p = CGPoint(x: muzzle.x + (target.x - muzzle.x) * CGFloat(fire), y: muzzle.y + (target.y - muzzle.y) * CGFloat(fire) - CGFloat(sin(fire * .pi)) * 6)
                ZStack {
                    Capsule().fill(LinearGradient(colors: [Color.orange.opacity(0), Color.orange.opacity(0.9)], startPoint: .trailing, endPoint: .leading))
                        .frame(width: 18, height: 6).offset(x: 9)
                    Circle().fill(RadialGradient(colors: [.white, .yellow, .orange, Color.red.opacity(0)], center: .center, startRadius: 0, endRadius: 7))
                        .frame(width: 14, height: 14)
                }
                .position(p)
            }
            if t >= 2.45 && t < 2.62 {
                Circle().fill(RadialGradient(colors: [.white, .yellow.opacity(0.6), .clear], center: .center, startRadius: 0, endRadius: 20))
                    .frame(width: 40, height: 40).position(target)
            }

            // GOAL (crest = the O) + gold script beside it.
            goalWord(flashTeam: flashTeam)
                .scaleEffect(CGFloat(lerp(2.0, 1, goalIn)))
                .opacity(goalIn > 0 ? sceneOut : 0)
                .position(x: cx - 24, y: midY)

            FlipCard(angle: flipIn * 180 + flipOut * 180) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.7)], startPoint: .top, endPoint: .bottom))
                    Image(systemName: "soccerball").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(red: 0.25, green: 0.1, blue: 0.35))
                }
                .frame(width: 20, height: 20)
            } back: {
                Badge(team: us, size: CGFloat(lerp(20, 26, goalIn)))
                    .shadow(color: usColor.opacity(goalIn * 0.8), radius: 6)
            }
            .position(x: crestHome, y: midY)

            Text("What a goal!")
                .font(.custom("SnellRoundhand-Bold", size: 17))
                .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.92, blue: 0.55), Color(red: 0.86, green: 0.62, blue: 0.16)], startPoint: .top, endPoint: .bottom))
                .shadow(color: Color(red: 1, green: 0.5, blue: 0.1).opacity(0.7), radius: 4)
                .fixedSize()
                .scaleEffect(CGFloat(lerp(0.85, 1, easeOut(scriptIn))))
                .position(x: cx + 96, y: midY)
                .opacity(scriptIn * sceneOut * (goal.scorer == nil ? 1 : 1 - seg(t, 3.85, 4.0)))

            // Scorer + minute, shown in the taller peak.
            Text(goal.scorer.map { "\($0)\(goal.minute.map { "  \($0)" } ?? "")" } ?? (goal.minute ?? us.name))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                .fixedSize()
                .position(x: cx + 96, y: midY)
                .opacity(goal.scorer == nil ? 0 : seg(t, 3.95, 4.1) * sceneOut)
        }
        .frame(width: W, height: H)
        .clipped()
    }

    private func scoreBar(updated: Bool, bump: Double) -> some View {
        let home = goal.teamHome ? us : opp
        let away = goal.teamHome ? opp : us
        let arsAfter = goal.teamBefore + (updated ? 1 : 0)
        let hs = goal.teamHome ? arsAfter : goal.opponentScore
        let aSc = goal.teamHome ? goal.opponentScore : arsAfter
        return HStack(spacing: 6) {
            Badge(team: home, size: 20)
            Text(home.abbr).font(.system(size: 16, weight: .heavy))
            Text("\(hs)").font(.system(size: 18, weight: .black).monospacedDigit()).scaleEffect(CGFloat(goal.teamHome && updated ? bump : 1))
            Spacer().frame(width: 30)
            Text("\(aSc)").font(.system(size: 18, weight: .black).monospacedDigit()).scaleEffect(CGFloat(!goal.teamHome && updated ? bump : 1))
            Text(away.abbr).font(.system(size: 16, weight: .heavy))
            Badge(team: away, size: 20)
        }
        .foregroundStyle(.white)
    }

    private func goalWord(flashTeam: Bool) -> some View {
        let col: Color = flashTeam ? usColor : .white
        return HStack(spacing: 1) {
            Headline(text: "G", size: 26, color: col)
            Spacer().frame(width: 25)
            Headline(text: "AL", size: 26, color: col)
        }
    }
}

// MARK: - 2. Claude done: ball curls into a small net

struct DoneScene: View {
    let project: String
    let detail: String
    let t: Double
    static let p0 = CGPoint(x: 392, y: 6), c = CGPoint(x: 210, y: 46), p1 = CGPoint(x: 30, y: 21)
    static func bez(_ u: CGFloat) -> CGPoint {
        let a = (1 - u) * (1 - u), b = 2 * (1 - u) * u, d = u * u
        return CGPoint(x: a * p0.x + b * c.x + d * p1.x, y: a * p0.y + b * c.y + d * p1.y)
    }
    var body: some View {
        let flight = easeInOut(seg(t, 0.1, 0.85))
        let hit = t >= 0.85
        let ripple: Double = hit ? sin((t - 0.85) * 26) * exp(-(t - 0.85) * 4) : 0
        let text = springy(seg(t, 0.85, 1.25))
        let out = 1 - seg(t, 2.25, 2.6)
        let u = CGFloat(flight)
        let ballPos: CGPoint = hit ? CGPoint(x: Self.p1.x - CGFloat(ripple) * 4, y: Self.p1.y + CGFloat(min(t - 0.85, 0.4)) * 10) : Self.bez(u)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(LinearGradient(colors: [.black, Color(red: 0.02, green: 0.16, blue: 0.07)], startPoint: .leading, endPoint: .trailing))
            DoneNet(ripple: ripple, u: u, trailFade: hit ? max(0, 1 - (t - 0.85) * 2) : 1)
            SoccerBall(size: 10, spin: flight * 14).position(ballPos)
            HStack(spacing: 8) {
                Headline(text: "DONE", size: 24, color: Color(red: 0.45, green: 1, blue: 0.6))
                    .scaleEffect(CGFloat(lerp(1.6, 1, text)), anchor: .leading)
                Text(project).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(1).opacity(seg(t, 1.1, 1.35))
                Text(detail).font(.system(size: 15)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).opacity(seg(t, 1.2, 1.45))
            }
            .frame(height: stripH)
            .offset(x: 62)
            .opacity(text > 0 ? 1 : 0)
        }
        .frame(width: 400, height: stripH)
        .opacity(out)
    }
}

struct DoneNet: View {
    let ripple: Double
    let u: CGFloat
    let trailFade: Double
    var body: some View {
        Canvas { ctx, _ in
            let net = CGRect(x: 12, y: 8, width: 36, height: 26)
            let r = CGFloat(ripple)
            func bulge(_ i: Int, _ j: Int) -> CGFloat { r * 5 * sin(CGFloat(j) / 4 * .pi) * sin(CGFloat(i) / 6 * .pi) }
            var mesh = Path()
            for i in 0...6 {
                let x = net.minX + net.width * CGFloat(i) / 6
                mesh.move(to: CGPoint(x: x, y: net.minY))
                for j in 0...4 { mesh.addLine(to: CGPoint(x: x - bulge(i, j), y: net.minY + net.height * CGFloat(j) / 4)) }
            }
            for j in 0...4 {
                let y = net.minY + net.height * CGFloat(j) / 4
                mesh.move(to: CGPoint(x: net.minX, y: y))
                for i in 0...6 { mesh.addLine(to: CGPoint(x: net.minX + net.width * CGFloat(i) / 6 - bulge(i, j), y: y)) }
            }
            ctx.stroke(mesh, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            var posts = Path()
            posts.move(to: CGPoint(x: net.maxX, y: net.maxY)); posts.addLine(to: CGPoint(x: net.maxX, y: net.minY))
            posts.addLine(to: CGPoint(x: net.minX + 4, y: net.minY))
            ctx.stroke(posts, with: .color(.white), lineWidth: 1.6)
            for i in 0..<14 {
                let p = DoneScene.bez(CGFloat(i) / 13 * u)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.2, y: p.y - 1.2, width: 2.4, height: 2.4)), with: .color(.white.opacity(Double(i) / 13 * 0.35 * trailFade)))
            }
        }
    }
}

// MARK: - 3. Commit / push: passing move

struct CommitScene: View {
    let title: String
    let repo: String
    let message: String
    let t: Double
    private let players: [CGPoint] = [CGPoint(x: 12, y: 28), CGPoint(x: 34, y: 12), CGPoint(x: 56, y: 29), CGPoint(x: 78, y: 13), CGPoint(x: 100, y: 24)]
    var body: some View {
        let hop = 0.2, start = 0.12
        let idx = min(max(Int((t - start) / hop), 0), players.count - 1)
        let local = start + Double(idx) * hop
        let f = CGFloat(easeInOut(seg(t, local, local + hop)))
        let arrived = t >= start + hop * Double(players.count - 1)
        let a = players[idx], b = players[min(idx + 1, players.count - 1)]
        let ball = arrived ? players.last! : CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        let text = springy(seg(t, 0.95, 1.3))
        let out = 1 - seg(t, 2.45, 2.8)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(LinearGradient(colors: [Color(red: 0.02, green: 0.12, blue: 0.1), .black], startPoint: .leading, endPoint: .trailing))
            Canvas { ctx, _ in
                var line = Path()
                line.move(to: players[0])
                for p in players.dropFirst() { line.addLine(to: p) }
                ctx.stroke(line, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 3], dashPhase: CGFloat(-t * 30)))
                for (i, p) in players.enumerated() {
                    let touched = t >= start + Double(i) * hop
                    let r: CGFloat = touched ? 3.5 : 3
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(touched ? Color(red: 0.35, green: 0.95, blue: 0.75) : .white.opacity(0.5)))
                }
                if t > 0.95 {
                    var c = ctx
                    c.scaleBy(x: 0.5, y: 0.5)
                    Particles.confetti(&c, origin: CGPoint(x: 260, y: 30), t: t - 0.95, count: 28)
                }
            }
            SoccerBall(size: 8, spin: t * 18).position(x: ball.x, y: ball.y - 6)
            HStack(spacing: 8) {
                Headline(text: title, size: 22, color: Color(red: 0.45, green: 1, blue: 0.8))
                    .scaleEffect(CGFloat(lerp(1.5, 1, text)), anchor: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    Text(repo).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                .opacity(seg(t, 1.1, 1.35))
            }
            .frame(width: 270, height: stripH, alignment: .leading)
            .offset(x: 118)
            .opacity(text > 0 ? 1 : 0)
        }
        .frame(width: 400, height: stripH)
        .opacity(out)
    }
}

// MARK: - 4. Push / deploy: volley + floodlights

struct DeployScene: View {
    let title: String
    let project: String
    let t: Double
    var body: some View {
        let volley = easeIn(seg(t, 0.1, 0.5))
        let lightsOn = seg(t, 0.5, 0.7)
        let flash = t > 0.5 && t < 0.75 ? (1 - seg(t, 0.5, 0.75)) : 0
        let text = springy(seg(t, 0.65, 1.05))
        let out = 1 - seg(t, 2.45, 2.8)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(LinearGradient(colors: [Color(red: 0.02, green: 0.04, blue: 0.14), .black], startPoint: .top, endPoint: .bottom))
            Canvas { ctx, size in
                for k in 0..<4 {
                    let base = CGPoint(x: k < 2 ? CGFloat(14 + k * 22) : size.width - CGFloat(14 + (k - 2) * 22), y: size.height + 2)
                    let ang = (k < 2 ? -1.0 : -2.15) + sin(t * 1.8 + Double(k)) * 0.3
                    let len: CGFloat = 150, spread = 0.13
                    var beam = Path()
                    beam.move(to: base)
                    beam.addLine(to: CGPoint(x: base.x + CGFloat(cos(ang - spread)) * len, y: base.y + CGFloat(sin(ang - spread)) * len))
                    beam.addLine(to: CGPoint(x: base.x + CGFloat(cos(ang + spread)) * len, y: base.y + CGFloat(sin(ang + spread)) * len))
                    beam.closeSubpath()
                    ctx.fill(beam, with: .linearGradient(Gradient(colors: [Color(red: 0.85, green: 0.92, blue: 1).opacity(0.4 * lightsOn), .clear]),
                                                         startPoint: base, endPoint: CGPoint(x: base.x + CGFloat(cos(ang)) * len, y: base.y + CGFloat(sin(ang)) * len)))
                }
                if t < 0.65 {
                    let s0 = CGPoint(x: 20, y: 34), e = CGPoint(x: 400, y: -6)
                    for i in 0..<10 {
                        let s = max(0, volley - Double(i) * 0.03)
                        let p = CGPoint(x: s0.x + (e.x - s0.x) * CGFloat(s), y: s0.y + (e.y - s0.y) * CGFloat(s))
                        let r = CGFloat(3.4 - Double(i) * 0.25)
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                 with: .color(Color(red: 1, green: 0.85 - Double(i) * 0.05, blue: 0.4).opacity(0.9 - Double(i) * 0.08)))
                    }
                }
            }
            Rectangle().fill(Color.white.opacity(flash * 0.5))
            HStack(spacing: 8) {
                Headline(text: title, size: 24, color: .white)
                    .shadow(color: Color(red: 0.4, green: 0.65, blue: 1).opacity(0.9), radius: 6)
                    .scaleEffect(CGFloat(lerp(0.4, 1, text)))
                Text(project).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).opacity(seg(t, 0.95, 1.2))
            }
            .frame(width: 400, height: stripH)
            .opacity(text > 0 ? 1 : 0)
        }
        .frame(width: 400, height: stripH)
        .opacity(out)
    }
}

// MARK: - 5. Failure: the referee's red card

struct RedCardScene: View {
    let title: String
    let line: String
    let t: Double
    var body: some View {
        let drop = springy(seg(t, 0.05, 0.55))
        let flip = easeOut(seg(t, 0.05, 0.4))
        let text = seg(t, 0.45, 0.75)
        let out = 1 - seg(t, 2.3, 2.6)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(LinearGradient(colors: [Color(red: 0.28, green: 0, blue: 0), .black], startPoint: .leading, endPoint: .trailing))
            FlipCard(angle: 180 - flip * 180) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.15, blue: 0.15), Color(red: 0.75, green: 0, blue: 0)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 18, height: 26)
            } back: {
                RoundedRectangle(cornerRadius: 2.5).fill(Color(white: 0.9)).frame(width: 18, height: 26)
            }
            .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
            .rotationEffect(.degrees(-10 + 10 * drop))
            .position(x: 22, y: CGFloat(lerp(-20, 20, drop)))
            HStack(spacing: 8) {
                Headline(text: title, size: 20, color: Color(red: 1, green: 0.4, blue: 0.4))
                Text(line).font(.system(size: 14, design: .monospaced)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
            .frame(width: 350, height: stripH, alignment: .leading)
            .offset(x: 44, y: CGFloat(1 - text) * 4)
            .opacity(text)
        }
        .frame(width: 400, height: stripH)
        .opacity(out)
    }
}

// MARK: - 6. PR merged: trophy lift

struct TrophyShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: w * 0.18, y: 0))
        p.addLine(to: CGPoint(x: w * 0.82, y: 0))
        p.addCurve(to: CGPoint(x: w * 0.56, y: h * 0.6), control1: CGPoint(x: w * 0.82, y: h * 0.4), control2: CGPoint(x: w * 0.7, y: h * 0.55))
        p.addLine(to: CGPoint(x: w * 0.56, y: h * 0.75))
        p.addLine(to: CGPoint(x: w * 0.72, y: h * 0.82))
        p.addLine(to: CGPoint(x: w * 0.72, y: h))
        p.addLine(to: CGPoint(x: w * 0.28, y: h))
        p.addLine(to: CGPoint(x: w * 0.28, y: h * 0.82))
        p.addLine(to: CGPoint(x: w * 0.44, y: h * 0.75))
        p.addLine(to: CGPoint(x: w * 0.44, y: h * 0.6))
        p.addCurve(to: CGPoint(x: w * 0.18, y: 0), control1: CGPoint(x: w * 0.3, y: h * 0.55), control2: CGPoint(x: w * 0.18, y: h * 0.4))
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: 0, y: h * 0.06, width: w * 0.3, height: h * 0.3))
        p.addEllipse(in: CGRect(x: w * 0.7, y: h * 0.06, width: w * 0.3, height: h * 0.3))
        return p
    }
}

struct TrophyScene: View {
    let repo: String
    let title: String
    let t: Double
    var body: some View {
        let lift = easeOut(seg(t, 0.1, 0.7))
        let bob = t > 0.7 ? sin((t - 0.7) * 7) * 2 * exp(-(t - 0.7) * 1.5) : 0
        let text = springy(seg(t, 0.55, 0.95))
        let out = 1 - seg(t, 2.45, 2.8)
        let gold = LinearGradient(colors: [Color(red: 1, green: 0.93, blue: 0.55), Color(red: 0.85, green: 0.6, blue: 0.12), Color(red: 1, green: 0.85, blue: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(RadialGradient(colors: [Color(red: 0.28, green: 0.2, blue: 0.02), .black], center: UnitPoint(x: 0.06, y: 0.5), startRadius: 0, endRadius: 160))
            Canvas { ctx, size in
                Particles.twinkles(&ctx, size: size, t: t, from: 0.45, color: Color(red: 1, green: 0.88, blue: 0.4), count: 22)
            }
            TrophyShape().fill(gold)
                .frame(width: 20, height: 25)
                .shadow(color: Color(red: 1, green: 0.75, blue: 0.2).opacity(0.6), radius: 5)
                .position(x: 24, y: CGFloat(lerp(60, 20, lift) - bob))
            HStack(spacing: 8) {
                Headline(text: "MERGED", size: 22, color: Color(red: 1, green: 0.85, blue: 0.35))
                    .scaleEffect(CGFloat(lerp(1.5, 1, text)), anchor: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    Text(repo).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                .opacity(seg(t, 0.8, 1.05))
            }
            .frame(width: 340, height: stripH, alignment: .leading)
            .offset(x: 48)
            .opacity(text > 0 ? 1 : 0)
        }
        .frame(width: 400, height: stripH)
        .opacity(out)
    }
}

// MARK: - 7. Task ticked: split-flap digits + tiny net bulge

struct FlapDigit: View {
    let old: Int
    let new: Int
    let p: Double
    var body: some View {
        // Top half of the old digit folds down, then the new bottom half folds in.
        let topScale = max(0.02, 1 - min(p * 2, 1))
        let bottomScale = max(0.02, max(p * 2 - 1, 0))
        ZStack {
            half(new, top: true)
            half(old, top: false)
            if p < 0.5 { half(old, top: true).scaleEffect(x: 1, y: topScale, anchor: .bottom).brightness(-0.25 * (1 - topScale)) }
            else { half(new, top: false).scaleEffect(x: 1, y: bottomScale, anchor: .top) }
        }
        .frame(width: 18, height: 26)
    }
    private func half(_ n: Int, top: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.15))
            Text("\(n)").font(.system(size: 18, weight: .heavy).monospacedDigit()).foregroundStyle(.white)
        }
        .frame(width: 18, height: 26)
        .mask(Rectangle().frame(height: 13).frame(maxHeight: .infinity, alignment: top ? .top : .bottom))
        .overlay(Rectangle().fill(Color.black.opacity(0.7)).frame(height: 0.8))
    }
}

struct FlapScene: View {
    let done: Int
    let left: Int
    let t: Double
    var body: some View {
        let flip = easeInOut(seg(t, 0.12, 0.55))
        let bulge = t > 0.55 ? sin(seg(t, 0.55, 1.0) * .pi) : 0
        let out = 1 - seg(t, 1.6, 1.9)
        ZStack {
            Rectangle().fill(LinearGradient(colors: [Color(white: 0.07), .black], startPoint: .top, endPoint: .bottom))
            HStack(spacing: 7) {
                Text("YOU").font(.system(size: 16, weight: .heavy)).foregroundStyle(.white)
                FlapDigit(old: max(done - 1, 0), new: done, p: flip)
                Text("–").font(.system(size: 14, weight: .heavy)).foregroundStyle(.white.opacity(0.6))
                FlapDigit(old: left + 1, new: left, p: flip)
                Text("TO-DO").font(.system(size: 16, weight: .heavy)).foregroundStyle(.white.opacity(0.7))
                ZStack {
                    RoundedRectangle(cornerRadius: 2).stroke(.white, lineWidth: 1.2).frame(width: 22, height: 16)
                    Canvas { ctx, size in
                        var m = Path()
                        for i in 0...4 {
                            let x = size.width * CGFloat(i) / 4
                            m.move(to: CGPoint(x: x, y: 0)); m.addLine(to: CGPoint(x: x + CGFloat(bulge) * 2, y: size.height))
                        }
                        for j in 0...3 {
                            let y = size.height * CGFloat(j) / 3
                            m.move(to: CGPoint(x: 0, y: y)); m.addQuadCurve(to: CGPoint(x: size.width, y: y), control: CGPoint(x: size.width / 2 + CGFloat(bulge) * 4, y: y + CGFloat(bulge) * 2))
                        }
                        ctx.stroke(m, with: .color(.white.opacity(0.4)), lineWidth: 0.5)
                    }
                    .frame(width: 20, height: 14)
                    SoccerBall(size: 6).offset(x: CGFloat(lerp(-24, 3, seg(t, 0.4, 0.6))), y: 2).opacity(t > 0.4 ? 1 : 0)
                }
                .scaleEffect(CGFloat(1 + bulge * 0.18))
            }
        }
        .frame(width: 400, height: stripH)
        .opacity(out)
    }
}

// MARK: - 8. Whistle: half-time / full-time

struct WhistleScene: View {
    let fullTime: Bool
    let title: String
    let detail: String
    let t: Double
    var body: some View {
        let shake = t < 0.9 ? sin(t * 60) * 3 * (1 - t / 0.9) : 0
        let sweep = easeInOut(seg(t, 0.3, 1.5)) * (fullTime ? 360 : 180)
        let text = springy(seg(t, 0.45, 0.85))
        let out = 1 - seg(t, 2.3, 2.6)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(LinearGradient(colors: [Color(white: 0.09), .black], startPoint: .leading, endPoint: .trailing))
            Canvas { ctx, _ in
                let origin = CGPoint(x: 30, y: 20)
                for k in 0..<3 {
                    let age = t - Double(k) * 0.22
                    guard age > 0, age < 1.2 else { continue }
                    var arc = Path()
                    arc.addArc(center: origin, radius: CGFloat(6 + age * 18), startAngle: .degrees(-40), endAngle: .degrees(40), clockwise: false)
                    ctx.stroke(arc, with: .color(.white.opacity(1 - age / 1.2)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.65)], startPoint: .top, endPoint: .bottom)).frame(width: 14, height: 14)
                RoundedRectangle(cornerRadius: 1.5).fill(Color(white: 0.85)).frame(width: 12, height: 5).offset(x: -8, y: -4)
                Circle().fill(Color(white: 0.3)).frame(width: 4, height: 4)
            }
            .rotationEffect(.degrees(shake * 2))
            .position(x: 20, y: 21)
            HStack(spacing: 8) {
                Headline(text: title, size: 22)
                    .scaleEffect(CGFloat(lerp(1.4, 1, text)), anchor: .leading)
                Text(detail).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
            .frame(width: 300, height: stripH, alignment: .leading)
            .offset(x: 60)
            .opacity(text > 0 ? 1 : 0)
            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 1.6)
                Circle().trim(from: 0, to: CGFloat(sweep / 360)).stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round)).rotationEffect(.degrees(-90))
                Capsule().fill(.white).frame(width: 1.2, height: 7).offset(y: -3.5).rotationEffect(.degrees(sweep))
            }
            .frame(width: 20, height: 20)
            .position(x: 378, y: 20)
        }
        .frame(width: 400, height: stripH)
        .opacity(out)
    }
}

// MARK: - 9. Meeting kick-off

struct KickoffScene: View {
    let title: String
    let joinURL: URL?
    let t: Double
    var body: some View {
        let W: CGFloat = joinURL == nil ? 380 : 420
        let roll = easeOut(seg(t, 0.4, 1.2))
        let text = springy(seg(t, 0.2, 0.55))
        let dur = CelebrationKind.kickoff(title: title, joinURL: joinURL).duration
        let out = 1 - seg(t, dur - 0.35, dur)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(LinearGradient(colors: [Color(red: 0.03, green: 0.2, blue: 0.08), Color(red: 0.01, green: 0.1, blue: 0.04)], startPoint: .top, endPoint: .bottom))
            Canvas { ctx, size in
                let c = CGPoint(x: 26, y: 20)
                var lines = Path()
                lines.move(to: CGPoint(x: c.x, y: 0)); lines.addLine(to: CGPoint(x: c.x, y: size.height))
                lines.addEllipse(in: CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26))
                ctx.stroke(lines.trimmedPath(from: 0, to: easeOut(seg(t, 0, 0.4))), with: .color(.white.opacity(0.7)), lineWidth: 1)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)), with: .color(.white))
            }
            SoccerBall(size: 8, spin: roll * 10).position(x: 26 + CGFloat(roll) * 22, y: 20)
            HStack(spacing: 8) {
                Headline(text: "KICK-OFF IN 5", size: 20)
                    .scaleEffect(CGFloat(lerp(1.3, 1, text)), anchor: .leading)
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            }
            .frame(width: W - (joinURL == nil ? 70 : 140), height: stripH, alignment: .leading)
            .offset(x: 58)
            .opacity(text > 0 ? 1 : 0)
            if let url = joinURL {
                Button {
                    NSWorkspace.shared.open(url)
                    IslandModel.shared.endCelebration()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "video.fill").font(.system(size: 14))
                        Text("Join").font(.system(size: 17, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(Capsule().fill(.white))
                }
                .buttonStyle(PressScaleStyle())
                .position(x: W - 62, y: 20)
                .opacity(seg(t, 0.7, 1.0))
            }
        }
        .frame(width: W, height: stripH)
        .opacity(out)
    }
}

// MARK: - 10. Crowd wave (timer done, end of day)

struct CrowdScene: View {
    let title: String
    let score: String
    let t: Double
    var body: some View {
        let text = springy(seg(t, 0.8, 1.2))
        let out = 1 - seg(t, 2.45, 2.8)
        ZStack {
            Rectangle().fill(LinearGradient(colors: [Color(red: 0.09, green: 0.05, blue: 0.13), .black], startPoint: .top, endPoint: .bottom))
            Canvas { ctx, size in
                let cols = 70, rows = 2
                let palette: [Color] = [Color(red: 1, green: 0.4, blue: 0.3), Color(red: 0.4, green: 0.6, blue: 1), Color(red: 1, green: 0.85, blue: 0.3), .white]
                for r in 0..<rows {
                    for c in 0..<cols {
                        let x = CGFloat(c) / CGFloat(cols - 1) * (size.width - 12) + 6
                        let baseY = size.height - 5 - CGFloat(r) * 5
                        let phase = (t * 1.3 - Double(c) / Double(cols)) * 2 * .pi
                        let up = max(0, sin(phase)) * (t < 2.4 ? 1 : 0)
                        let y = baseY - CGFloat(up) * 5
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 1.3, y: y - 1.3, width: 2.6, height: 2.6)),
                                 with: .color(palette[(c + r) % palette.count].opacity(0.35 + up * 0.65)))
                    }
                }
            }
            HStack(spacing: 8) {
                Headline(text: title, size: 20).scaleEffect(CGFloat(lerp(1.4, 1, text)))
                Text(score).font(.system(size: 16, weight: .bold).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
            }
            .offset(y: -6)
            .opacity(text > 0 ? 1 : 0)
        }
        .frame(width: 400, height: stripH)
        .opacity(out)
    }
}

// MARK: - 11. Cinema intro: colour ribbons stream through the pill, fan out, collapse into the glow
// (our own design; inspired by ribbon-style film intros, not any studio's logo)

struct CinemaIntroScene: View {
    let t: Double
    private static let W: CGFloat = 400
    private static let n = 30
    /// Deep cinema hues: reds, magentas, purples, golds (full brightness, never pastel).
    private static let hues: [Double] = [0.99, 0.95, 0.91, 0.86, 0.80, 0.76, 0.12, 0.08, 0.03]

    var body: some View {
        let stream = seg(t, 0.0, 0.8)           // ribbons rush in from the centre line
        let fan = easeOut(seg(t, 0.6, 1.6))     // spread across the pill
        let collapse = easeIn(seg(t, 1.7, 2.4)) // squeezed to the edges: becomes the glow
        let flare = sin(seg(t, 0.5, 1.3) * .pi)
        let time = t
        return Canvas { ctx, _ in
            ctx.fill(Path(CGRect(x: 0, y: 0, width: Self.W, height: stripH)), with: .color(.black))
            // Bloom: a blurred, additive copy underneath the crisp ribbons.
            ctx.drawLayer { bloom in
                bloom.addFilter(.blur(radius: 7))
                bloom.blendMode = .plusLighter
                for i in 0..<Self.n { Self.ribbon(&bloom, i: i, t: time, stream: stream, fan: fan, collapse: collapse, widthScale: 2.2) }
            }
            ctx.drawLayer { core in
                core.blendMode = .plusLighter
                for i in 0..<Self.n { Self.ribbon(&core, i: i, t: time, stream: stream, fan: fan, collapse: collapse, widthScale: 1) }
            }
            ctx.drawLayer { f in
                f.addFilter(.blur(radius: 4))
                f.fill(Path(CGRect(x: Self.W / 2 - 3, y: 0, width: 6, height: stripH)), with: .color(.white.opacity(0.95 * flare)))
            }
        }
        .frame(width: Self.W, height: stripH)
        .opacity(1 - seg(t, 2.3, 2.5))
        .overlay { Self.label(t) }
    }

    /// "CINEMA MODE": appears as the ribbons become the glow, holds ~1.2 s, then dissolves.
    @ViewBuilder static func label(_ t: Double) -> some View {
        let appear = easeOut(seg(t, 1.9, 2.25))
        let dissolve = easeIn(seg(t, 3.15, 3.6))
        let a = appear * (1 - dissolve)
        Text("CINEMA MODE")
            .font(.system(size: 14, weight: .bold))
            .tracking(4.5 + 2.5 * dissolve)
            .foregroundStyle(.white)
            .shadow(color: Color(hue: 0.93, saturation: 0.9, brightness: 1).opacity(0.9 * a), radius: 6)
            .shadow(color: Color(hue: 0.08, saturation: 0.9, brightness: 1).opacity(0.6 * a), radius: 12)
            .scaleEffect(0.94 + 0.06 * appear + 0.04 * dissolve)
            .blur(radius: 3 * dissolve + 2 * (1 - appear))
            .opacity(a)
    }

    private static func ribbon(_ ctx: inout GraphicsContext, i: Int, t: Double, stream: Double, fan: Double, collapse: Double, widthScale: CGFloat) {
        let f = Double(i) / Double(n - 1)
        let hue = hues[i % hues.count]
        let centreX = W / 2
        let slot = CGFloat(f) * W
        var x: CGFloat = centreX + (slot - centreX) * CGFloat(fan)
        let edge: CGFloat = f < 0.5 ? 0 : W
        x += (edge - x) * CGFloat(collapse)
        let thick: Double = (3 + 8 * (1 - abs(f - 0.5) * 2)) * (1 - collapse * 0.5)
        let width = CGFloat(thick) * widthScale
        let speed = 0.6 + rnd(i, 3) * 0.8
        let travel: Double = (t * speed * 120 + rnd(i, 4) * 60).truncatingRemainder(dividingBy: 80)
        let yOff = CGFloat(travel) - 40
        let visible = stream * (1 - collapse * 0.7)
        let rect = CGRect(x: x - width / 2, y: yOff - 6, width: width, height: stripH + 12)
        let col = Color(hue: hue, saturation: 1, brightness: 1)
        let grad = Gradient(colors: [col.opacity(0), col.opacity(visible), col.opacity(0)])
        ctx.fill(Path(roundedRect: rect, cornerRadius: width / 2),
                 with: .linearGradient(grad, startPoint: CGPoint(x: x, y: rect.minY), endPoint: CGPoint(x: x, y: rect.maxY)))
    }
}
