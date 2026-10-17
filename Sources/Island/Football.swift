import AppKit
import SwiftUI
import Observation

// Football mode: follow one team you pick in Settings › Football. Live score in the pill,
// a Home card, a matchday theme and a goal celebration.
//
// Data comes from a FootballDataSource (FootballSource.swift). The default one reads ESPN's
// public site JSON, which is unofficial. Club names and badges belong to their clubs; badges are
// downloaded from the data source when shown and cached on this Mac only. None are in the repo.

// MARK: - Model

struct TeamInfo: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var abbr: String
    var name: String
    var logo: String?
    var color: String?   // hex from the feed, e.g. "132257"

    /// Fictional teams for previews and the demo goal. They have no badge and are never fetched.
    static let demoHome = TeamInfo(id: "demo-home", abbr: "GFC", name: "Glance FC", logo: nil, color: "1f6feb")
    static let demoAway = TeamInfo(id: "demo-away", abbr: "RIV", name: "Rivals", logo: nil, color: "6b7280")
    var isDemo: Bool { id.hasPrefix("demo-") }

    var nsColor: NSColor? {
        guard let h = color, h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// The team colour, kept bright enough to read on a black strip. Neutral blue when unknown.
    var displayColor: NSColor {
        let fallback = NSColor(srgbRed: 0.12, green: 0.44, blue: 0.92, alpha: 1)
        guard let c = nsColor?.usingColorSpace(.sRGB) else { return fallback }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.15 { return fallback }   // white, black or grey kits: use the neutral colour
        return NSColor(hue: h, saturation: max(s, 0.6), brightness: max(b, 0.75), alpha: 1)
    }
}

/// The team you follow, as saved in Settings.
struct FollowedTeam: Codable, Equatable {
    var league: String = "eng.1"
    var team: TeamInfo? = nil
}

struct MatchInfo: Codable, Equatable {
    var id: String
    var league: String          // data source league id, e.g. "eng.1"
    var leagueName: String
    var date: Date
    var home: TeamInfo
    var away: TeamInfo
    var homeScore: Int
    var awayScore: Int
    var state: String           // pre / in / post
    var statusName: String      // STATUS_HALFTIME, STATUS_FULL_TIME, ...
    var clock: String           // "67'"
    var myTeamID: String = ""   // the followed team, so the views know which side is "us"

    var teamHome: Bool { myTeamID.isEmpty || home.id == myTeamID }
    var team: TeamInfo { teamHome ? home : away }
    var opponent: TeamInfo { teamHome ? away : home }
    var teamScore: Int { teamHome ? homeScore : awayScore }
    var opponentScore: Int { teamHome ? awayScore : homeScore }
    var isLive: Bool { state == "in" }
    var resultLetter: String { teamScore > opponentScore ? "W" : (teamScore == opponentScore ? "D" : "L") }
}

/// Something that happened in a match: a goal or a red card.
struct MatchEvent: Equatable {
    enum Kind { case goal, redCard }
    var kind: Kind
    var teamID: String?
    var player: String?
    var minute: String?
}

struct GoalEvent: Equatable {
    var team: TeamInfo
    var opponent: TeamInfo
    var teamHome: Bool
    var teamBefore: Int
    var opponentScore: Int
    var scorer: String?
    var minute: String?

    static let demo = GoalEvent(team: .demoHome, opponent: .demoAway, teamHome: false, teamBefore: 0, opponentScore: 0, scorer: nil, minute: nil)
}

// MARK: - Badge cache (downloaded at runtime from the data source, cached on disk; never bundled)

@Observable @MainActor
final class BadgeCache {
    static let shared = BadgeCache()
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    private var dir: URL {
        let u = Env.cachesBase.appendingPathComponent("Glance/badges", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func image(for team: TeamInfo) -> NSImage? {
        if let i = images[team.id] { return i }
        load(team)
        return nil
    }

    func load(_ team: TeamInfo) {
        guard !team.isDemo, images[team.id] == nil, !loading.contains(team.id) else { return }
        let safeID = team.id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !safeID.isEmpty else { return }
        let file = dir.appendingPathComponent("\(safeID).png")
        if let img = NSImage(contentsOf: file) { images[team.id] = img; return }
        guard let url = FootballService.shared.source.badgeURL(for: team) else { return }
        loading.insert(team.id)
        Task {
            defer { self.loading.remove(team.id) }
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = NSImage(data: data) else { return }
            // Keep them small in memory and on disk.
            let small = NowPlaying.downscale(img, to: 128)
            if let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: file)
            }
            self.images[team.id] = small
        }
    }
}

// MARK: - Service

@Observable @MainActor
final class FootballService {
    static let shared = FootballService()

    /// The data source. Swap this to use another provider (see FootballSource.swift).
    @ObservationIgnored var source: FootballDataSource = ESPNFootballSource()

    var next: MatchInfo?
    var last: MatchInfo?
    var live: MatchInfo?
    var standing: String?           // "2nd in English Premier League"
    var lastGoal: GoalEvent?
    var finishedUnwatched: MatchInfo?   // spoiler-free: result waiting to be revealed

    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var liveTimer: Timer?
    @ObservationIgnored private var kickoffTimer: Timer?
    @ObservationIgnored private var seenEventKeys: Set<String> = []
    @ObservationIgnored private var lastLiveStatus: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var startedFor: String?

    private var prefs: Prefs { AppSettings.shared.prefs }

    /// The followed team, or nil until one is picked in Settings.
    var team: TeamInfo? { prefs.footballTeam.team }
    var teamID: String? { team?.id }

    var isMatchday: Bool {
        guard let m = live ?? next else { return false }
        return m.isLive || Calendar.current.isDateInToday(m.date)
    }

    /// The live pill is shown only when allowed (not spoiler-free).
    var pillMatch: MatchInfo? {
        guard prefs.footballMode, prefs.footballLivePill, !prefs.spoilerFree, let m = live, m.isLive || m.statusName == "STATUS_HALFTIME" else { return nil }
        return m
    }

    func start() {
        guard prefs.footballMode, let id = teamID else { stop(); return }
        let key = "\(prefs.footballTeam.league)/\(id)"
        if started && startedFor == key { return }
        if started { stop() }
        started = true
        startedFor = key
        refresh()
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { _ in MainActor.assumeIsolated { FootballService.shared.refresh() } }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func stop() {
        started = false
        startedFor = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        liveTimer?.invalidate(); liveTimer = nil
        kickoffTimer?.invalidate(); kickoffTimer = nil
        live = nil
        next = nil
        last = nil
        standing = nil
        lastGoal = nil
        finishedUnwatched = nil
    }

    /// Called when the followed team changes in Settings.
    func teamChanged() {
        stop()
        start()
    }

    // MARK: Fetching

    func refresh() {
        guard let team else { return }
        let league = prefs.footballTeam.league
        let src = source
        Task {
            let overview = await src.overview(teamID: team.id, league: league)
            guard self.teamID == team.id else { return }   // the team changed meanwhile
            standing = overview.standing
            var latest: MatchInfo?
            var soonest: MatchInfo?
            for var m in overview.matches {
                m.myTeamID = team.id
                if m.state == "post", m.date < Date(), m.date > (latest?.date ?? .distantPast) { latest = m }
                if m.state != "post", m.date > Date().addingTimeInterval(-3 * 3600), m.date < (soonest?.date ?? .distantFuture) { soonest = m }
            }
            next = soonest
            if let l = latest {
                last = l
                await loadLastGoal(for: l)
            }
            if let n = next { BadgeCache.shared.load(n.opponent) }
            if let l = last { BadgeCache.shared.load(l.opponent) }
            BadgeCache.shared.load(team)
            scheduleLive()
        }
    }

    /// Scorer and minute of the team's last goal in a finished match, for "Replay goal".
    private func loadLastGoal(for m: MatchInfo) async {
        guard m.teamScore > 0, let snap = await source.liveUpdate(for: m), teamID == m.team.id else { return }
        let g = snap.events.last { $0.kind == .goal && $0.teamID == m.team.id }
        lastGoal = GoalEvent(team: m.team, opponent: m.opponent, teamHome: m.teamHome, teamBefore: max(0, m.teamScore - 1),
                             opponentScore: m.opponentScore, scorer: g?.player, minute: g?.minute)
    }

    /// Polls every 30 s only from 10 min before kick-off until full time.
    private func scheduleLive() {
        kickoffTimer?.invalidate()
        guard let n = next else { return }
        let startPoll = n.date.addingTimeInterval(-600)
        let endWindow = n.date.addingTimeInterval(3 * 3600)
        let now = Date()
        if now >= startPoll && now <= endWindow {
            startLivePolling(n)
        } else if startPoll > now, startPoll.timeIntervalSince(now) < 7 * 86400 {
            let t = Timer(fire: startPoll, interval: 0, repeats: false) { _ in
                MainActor.assumeIsolated { if let n = FootballService.shared.next { FootballService.shared.startLivePolling(n) } }
            }
            t.tolerance = 30
            RunLoop.main.add(t, forMode: .common)
            kickoffTimer = t
        }
    }

    private func startLivePolling(_ m: MatchInfo) {
        guard liveTimer == nil else { return }
        live = m
        lastLiveStatus = m.statusName
        seenEventKeys = []
        let t = Timer(timeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { FootballService.shared.pollLive() } }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
        pollLive()
    }

    private func pollLive() {
        guard let cur = live else { liveTimer?.invalidate(); liveTimer = nil; return }
        Task {
            guard var snap = await source.liveUpdate(for: cur) else { return } // offline: fail quietly
            snap.match.league = cur.league
            snap.match.myTeamID = cur.myTeamID
            apply(update: snap.match, previous: cur, events: snap.events)
        }
    }

    func apply(update m: MatchInfo, previous cur: MatchInfo, events: [MatchEvent]) {
        let p = prefs
        let model = IslandModel.shared
        let spoiler = p.spoilerFree
        live = m
        // Kick-off, half-time, full-time.
        if cur.state == "pre" && m.state == "in" {
            model.enqueue(Peek(symbol: "sportscourt.fill", title: "Kick-off", subtitle: "\(m.home.abbr) v \(m.away.abbr)", tint: .red, duration: 3.5))
            Feedback.haptic(.levelChange)
        }
        if m.statusName == "STATUS_HALFTIME" && lastLiveStatus != "STATUS_HALFTIME" {
            model.enqueue(Peek(symbol: "pause.circle.fill", title: "Half-time", subtitle: spoiler ? nil : "\(m.home.abbr) \(m.homeScore)–\(m.awayScore) \(m.away.abbr)", tint: .white, duration: 3.5))
        }
        lastLiveStatus = m.statusName
        // Goals.
        if !spoiler {
            if m.teamScore > cur.teamScore {
                let g = events.last { $0.kind == .goal && $0.teamID == m.team.id }
                let goal = GoalEvent(team: m.team, opponent: m.opponent, teamHome: m.teamHome, teamBefore: m.teamScore - 1,
                                     opponentScore: m.opponentScore, scorer: g?.player, minute: g?.minute)
                lastGoal = goal
                model.celebrate(.teamGoal(goal))
            } else if m.opponentScore > cur.opponentScore {
                model.shakePill()
            }
            // Red cards.
            for e in events where e.kind == .redCard {
                let key = "rc-\(e.minute ?? "")-\(e.player ?? "")"
                guard !seenEventKeys.contains(key) else { continue }
                seenEventKeys.insert(key)
                let side = e.teamID == m.team.id ? m.team.abbr : m.opponent.abbr
                model.enqueue(Peek(symbol: "rectangle.portrait.fill", title: "Red card", subtitle: "\(e.player ?? "Player") (\(side))", tint: .red, duration: 3.5))
            }
        }
        if m.state == "post" {
            liveTimer?.invalidate(); liveTimer = nil
            last = m
            live = nil
            next = nil
            if spoiler {
                finishedUnwatched = m
                var peek = Peek(symbol: "flag.checkered", title: "Full-time", subtitle: "vs \(m.opponent.abbr)", tint: .white, duration: 6)
                peek.actionTitle = "Watch the replay"
                peek.action = { FootballService.shared.watchReplay() }
                model.enqueue(peek)
            } else {
                model.enqueue(Peek(symbol: "flag.checkered", title: "Full-time", subtitle: "\(m.home.abbr) \(m.homeScore)–\(m.awayScore) \(m.away.abbr)", tint: .white, duration: 4))
            }
            Task { try? await Task.sleep(for: .seconds(60)); self.refresh() }
        }
    }

    /// Plays the last real goal of the followed team, or a demo with fictional teams.
    func playLastGoal() {
        IslandModel.shared.celebrate(.teamGoal(lastGoal ?? .demo))
    }

    func watchReplay() {
        finishedUnwatched = nil
        playLastGoal()
    }
}
