import Foundation

// MARK: - Pluggable football data source
//
// Football mode talks to its data through this protocol, so the provider can be swapped without
// touching the views or the goal celebration. To add a provider, implement FootballDataSource and
// set `FootballService.shared.source` to it (for example in AppDelegate before `start()`).
//
// Rules for any provider: no API keys in the repo, no bundled club badges (return a badge URL and
// Glance downloads and caches it at runtime), and poll gently (Glance asks every 6 hours, and
// every 30 seconds only while the followed team is playing).

struct FootballLeague: Identifiable, Hashable {
    let id: String     // the provider's league id, e.g. "eng.1"
    let name: String
}

/// What the Home card and the scheduler need for one team.
struct TeamOverview {
    var standing: String?          // "2nd in English Premier League"
    var matches: [MatchInfo]       // recent results and upcoming fixtures, any competition
}

/// A fresh look at one match: score, status and its goals and red cards.
struct LiveUpdate {
    var match: MatchInfo
    var events: [MatchEvent]
}

protocol FootballDataSource: Sendable {
    /// Shown in Settings, e.g. "ESPN public site feed (unofficial)".
    var name: String { get }
    /// Leagues offered in the team picker.
    var leagues: [FootballLeague] { get }
    /// Teams in a league, for the picker.
    func teams(league: String) async -> [TeamInfo]
    /// League position plus recent and upcoming matches of one team.
    func overview(teamID: String, league: String) async -> TeamOverview
    /// Current state of a match (live, or finished for the replay). Nil when offline.
    func liveUpdate(for match: MatchInfo) async -> LiveUpdate?
    /// Where to download a team's badge, or nil for none. Badges are never bundled.
    func badgeURL(for team: TeamInfo) -> URL?
}

// MARK: - ESPN (default, unofficial)

/// ESPN's public "site" JSON, the same feed espn.com uses. It needs no key, but it is **unofficial
/// and undocumented**: it is not a supported API, it can change or stop without notice, and ESPN's
/// terms apply. Glance is not affiliated with ESPN. Use it for personal use only.
struct ESPNFootballSource: FootballDataSource {
    let name = "ESPN public site feed (unofficial)"
    private let base = "https://site.api.espn.com/apis/site/v2/sports/soccer"

    let leagues: [FootballLeague] = [
        .init(id: "eng.1", name: "England: Premier League"),
        .init(id: "eng.2", name: "England: Championship"),
        .init(id: "esp.1", name: "Spain: LaLiga"),
        .init(id: "ger.1", name: "Germany: Bundesliga"),
        .init(id: "ita.1", name: "Italy: Serie A"),
        .init(id: "fra.1", name: "France: Ligue 1"),
        .init(id: "ned.1", name: "Netherlands: Eredivisie"),
        .init(id: "por.1", name: "Portugal: Primeira Liga"),
        .init(id: "sco.1", name: "Scotland: Premiership"),
        .init(id: "usa.1", name: "USA: MLS"),
    ]

    /// Competitions searched for a team's fixtures: its league, the main domestic cups and Europe.
    private func competitions(for league: String) -> [String] {
        let cups: [String: [String]] = [
            "eng.1": ["eng.fa", "eng.league_cup"],
            "eng.2": ["eng.fa", "eng.league_cup"],
            "esp.1": ["esp.copa_del_rey"],
            "ger.1": ["ger.dfb_pokal"],
            "ita.1": ["ita.coppa_italia"],
            "fra.1": ["fra.coupe_de_france"],
        ]
        let europe = league.hasPrefix("usa.") ? [] : ["uefa.champions", "uefa.europa", "uefa.europa.conf"]
        return [league] + (cups[league] ?? []) + europe
    }

    private func json(_ s: String) async -> [String: Any]? {
        guard let url = URL(string: s) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Glance/1.0 (macOS app; Football mode)", forHTTPHeaderField: "User-Agent")
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    func teams(league: String) async -> [TeamInfo] {
        guard let lg = league.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let root = await json("\(base)/\(lg)/teams"),
              let leagues = (root["sports"] as? [[String: Any]])?.first?["leagues"] as? [[String: Any]],
              let teams = leagues.first?["teams"] as? [[String: Any]] else { return [] }
        return teams.compactMap { ($0["team"] as? [String: Any]).map(Self.team) }
            .filter { $0.id != "?" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func overview(teamID: String, league: String) async -> TeamOverview {
        var out = TeamOverview(standing: nil, matches: [])
        // League position. The team endpoint's nextEvent is unreliable, so fixtures come from
        // each competition's schedule?fixture=true below; nextEvent is only a fallback.
        if let t = await json("\(base)/\(league)/teams/\(teamID)")?["team"] as? [String: Any] {
            out.standing = t["standingSummary"] as? String
            if let ne = (t["nextEvent"] as? [[String: Any]])?.first, var m = Self.parseEvent(ne), m.state != "post" {
                m.league = league
                out.matches.append(m)
            }
        }
        for lg in competitions(for: league) {
            for suffix in ["", "?fixture=true"] {
                guard let events = await json("\(base)/\(lg)/teams/\(teamID)/schedule\(suffix)")?["events"] as? [[String: Any]] else { continue }
                for e in events {
                    guard var m = Self.parseEvent(e) else { continue }
                    m.league = lg
                    out.matches.append(m)
                }
            }
        }
        return out
    }

    func liveUpdate(for match: MatchInfo) async -> LiveUpdate? {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.timeZone = TimeZone(identifier: "UTC")
        // Today's scoreboard first (live matches), then the scoreboard for the match date.
        for query in ["", "?dates=\(f.string(from: match.date))"] {
            guard let events = await json("\(base)/\(match.league)/scoreboard\(query)")?["events"] as? [[String: Any]],
                  let e = events.first(where: { ($0["id"] as? String) == match.id }),
                  let m = Self.parseEvent(e) else { continue }
            let details = ((e["competitions"] as? [[String: Any]])?.first?["details"] as? [[String: Any]]) ?? []
            return LiveUpdate(match: m, events: details.compactMap(Self.event))
        }
        return nil
    }

    func badgeURL(for team: TeamInfo) -> URL? {
        guard !team.isDemo else { return nil }
        if let s = team.logo, let u = URL(string: s), u.scheme == "https" { return u }
        guard team.id.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://a.espncdn.com/i/teamlogos/soccer/500/\(team.id).png")
    }

    // MARK: Parsing

    private static func team(_ t: [String: Any]) -> TeamInfo {
        let logo = (t["logos"] as? [[String: Any]])?.first?["href"] as? String ?? t["logo"] as? String
        return TeamInfo(id: t["id"] as? String ?? "?", abbr: t["abbreviation"] as? String ?? "???",
                        name: t["shortDisplayName"] as? String ?? t["displayName"] as? String ?? "", logo: logo, color: t["color"] as? String)
    }

    private static func event(_ d: [String: Any]) -> MatchEvent? {
        let kind: MatchEvent.Kind
        if (d["scoringPlay"] as? Bool) == true { kind = .goal }
        else if (d["redCard"] as? Bool) == true { kind = .redCard }
        else { return nil }
        return MatchEvent(kind: kind,
                          teamID: (d["team"] as? [String: Any])?["id"] as? String,
                          player: (d["athletesInvolved"] as? [[String: Any]])?.first?["displayName"] as? String,
                          minute: (d["clock"] as? [String: Any])?["displayValue"] as? String)
    }

    static func parseEvent(_ e: [String: Any]) -> MatchInfo? {
        guard let id = e["id"] as? String, let ds = e["date"] as? String,
              let c = (e["competitions"] as? [[String: Any]])?.first,
              let comps = c["competitors"] as? [[String: Any]], comps.count == 2 else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var date = iso.date(from: ds)
        if date == nil { iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withTimeZone]; date = iso.date(from: ds) }
        if date == nil {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"; f.timeZone = TimeZone(identifier: "UTC")
            date = f.date(from: ds)
        }
        guard let d = date else { return nil }
        func score(_ x: [String: Any]) -> Int {
            if let s = x["score"] as? String { return Int(s) ?? 0 }
            if let o = x["score"] as? [String: Any] { return Int((o["value"] as? Double) ?? Double(o["displayValue"] as? String ?? "0") ?? 0) }
            return 0
        }
        guard let h = comps.first(where: { ($0["homeAway"] as? String) == "home" }),
              let a = comps.first(where: { ($0["homeAway"] as? String) == "away" }) else { return nil }
        let status = (c["status"] as? [String: Any]) ?? (e["status"] as? [String: Any]) ?? [:]
        let type = status["type"] as? [String: Any] ?? [:]
        let league = e["league"] as? [String: Any]
        return MatchInfo(id: id, league: league?["slug"] as? String ?? "",
                         leagueName: league?["abbreviation"] as? String ?? league?["name"] as? String ?? "",
                         date: d, home: team(h["team"] as? [String: Any] ?? [:]), away: team(a["team"] as? [String: Any] ?? [:]),
                         homeScore: score(h), awayScore: score(a),
                         state: type["state"] as? String ?? "pre", statusName: type["name"] as? String ?? "",
                         clock: status["displayClock"] as? String ?? "")
    }
}
