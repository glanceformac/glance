import AppKit
import SwiftUI
import EventKit
import Observation

private func dayKey(_ d: Date = Date()) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
}

// MARK: - Focus as a match: "Focus 3–0 Distractions" (daily, 7-day history)

@Observable @MainActor
final class FocusMatch {
    static let shared = FocusMatch()
    private(set) var history: [String: [Int]] = [:]   // day -> [focus, distractions]
    private let key = "IslandFocusMatch.v1"

    private init() {
        if let d = Env.defaults.dictionary(forKey: key) as? [String: [Int]] { history = d }
        prune()
    }

    var today: (focus: Int, distractions: Int) {
        let v = history[dayKey()] ?? [0, 0]
        return (v[0], v.count > 1 ? v[1] : 0)
    }
    var scoreLine: String { "Focus \(today.focus)–\(today.distractions) Distractions" }

    func goal() { bump(0) }
    func distraction() {
        bump(1)
        IslandModel.shared.enqueue(Peek(symbol: "exclamationmark.bubble.fill", title: "Distraction", subtitle: "\(today.focus)–\(today.distractions)", tint: .orange, duration: 1.6))
    }

    private func bump(_ i: Int) {
        var v = history[dayKey()] ?? [0, 0]
        v[i] += 1
        history[dayKey()] = v
        prune()
        Env.defaults.set(history, forKey: key)
    }

    /// Keeps the last 7 days; "today" naturally resets at midnight because it is keyed by date.
    private func prune() {
        let keep = Set((0..<7).map { dayKey(Date().addingTimeInterval(-Double($0) * 86400)) })
        history = history.filter { keep.contains($0.key) }
    }

    var lastSevenDays: [(String, Int, Int)] {
        (0..<7).reversed().map { i in
            let d = Date().addingTimeInterval(-Double(i) * 86400)
            let v = history[dayKey(d)] ?? [0, 0]
            return (d.formatted(.dateTime.weekday(.narrow)), v[0], v.count > 1 ? v[1] : 0)
        }
    }
}

// MARK: - Daily to-do scoreboard: "You 4–1 To-do"

struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var done = false
    var doneDay: String?
}

@Observable @MainActor
final class TodoStore {
    static let shared = TodoStore()
    private(set) var items: [TodoItem] = []
    @ObservationIgnored private var endOfDayTimer: Timer?
    @ObservationIgnored private var midnightTimer: Timer?

    private var file: URL { ClaudeServer.directory.appendingPathComponent("today.json") }

    private init() {
        if let d = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([TodoItem].self, from: d) { items = list }
        rollOver()
    }

    var doneToday: Int { items.filter { $0.done && $0.doneDay == dayKey() }.count }
    var left: Int { items.filter { !$0.done }.count }
    var scoreLine: String { "You \(doneToday)–\(left) To-do" }

    func add(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        withAnimation(IslandModel.openSpring) { items.append(TodoItem(title: t)) }
        save()
    }

    func toggle(_ item: TodoItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation(IslandModel.openSpring) {
            items[i].done.toggle()
            items[i].doneDay = items[i].done ? dayKey() : nil
        }
        save()
        if items[i].done, AppSettings.shared.prefs.celebrations {
            IslandModel.shared.celebrate(.taskTicked(done: doneToday, left: left))
        }
    }

    func delete(_ item: TodoItem) {
        withAnimation(IslandModel.openSpring) { items.removeAll { $0.id == item.id } }
        save()
    }

    /// Done items from earlier days are cleared at midnight; unfinished ones carry over.
    private func rollOver() {
        let before = items.count
        items.removeAll { $0.done && $0.doneDay != dayKey() }
        if items.count != before { save() }
    }

    func scheduleTimers() {
        endOfDayTimer?.invalidate(); midnightTimer?.invalidate()
        let cal = Calendar.current
        let now = Date()
        if var eod = cal.date(bySettingHour: AppSettings.shared.prefs.endOfDayHour, minute: 0, second: 0, of: now) {
            if eod <= now { eod = cal.date(byAdding: .day, value: 1, to: eod)! }
            let t = Timer(fire: eod, interval: 0, repeats: false) { _ in MainActor.assumeIsolated { TodoStore.shared.endOfDay() } }
            t.tolerance = 30
            RunLoop.main.add(t, forMode: .common)
            endOfDayTimer = t
        }
        if let midnight = cal.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 5), matchingPolicy: .nextTime) {
            let t = Timer(fire: midnight, interval: 0, repeats: false) { _ in
                MainActor.assumeIsolated { TodoStore.shared.rollOver(); TodoStore.shared.scheduleTimers() }
            }
            t.tolerance = 60
            RunLoop.main.add(t, forMode: .common)
            midnightTimer = t
        }
    }

    private func endOfDay() {
        if AppSettings.shared.prefs.todoEnabled, !(doneToday == 0 && left == 0) {
            IslandModel.shared.celebrate(.crowdWave(title: "FULL-TIME", score: scoreLine))
        }
        scheduleTimers()
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(items) else { return }
        FileManager.default.createFile(atPath: file.path, contents: d, attributes: [.posixPermissions: 0o600])
    }
}

// MARK: - Meetings as kick-off

enum MeetingLinks {
    static let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "gotomeeting.com", "gotomeet.me", "webex.com", "whereby.com", "meet.jit.si", "around.co"]

    static func joinURL(for e: EKEvent) -> URL? {
        var texts: [String] = []
        if let u = e.url?.absoluteString { texts.append(u) }
        if let l = e.location { texts.append(l) }
        if let n = e.notes { texts.append(n) }
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for t in texts {
            for m in det.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                if let u = m.url, let h = u.host?.lowercased(), hosts.contains(where: { h.hasSuffix($0) }) { return u }
            }
        }
        return nil
    }
}

// MARK: - GitHub activity (via the logged-in `gh` CLI; the token is never read by Glance)

@Observable @MainActor
final class GitHubActivity {
    static let shared = GitHubActivity()
    private(set) var status = "Not started"
    private(set) var available = false

    @ObservationIgnored private var ghPath: String?
    @ObservationIgnored private var login: String?
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Pushes Glance already celebrated from Claude Code (repo name -> time).
    @ObservationIgnored var recentLocalPush: [String: Date] = [:]
    private let lastIDKey = "IslandGitHubLastEventID"

    func start() {
        guard AppSettings.shared.prefs.githubActivity, timer == nil else {
            if !AppSettings.shared.prefs.githubActivity { stop() }
            return
        }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { GitHubActivity.shared.asleep = true } })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { GitHubActivity.shared.asleep = false } })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { GitHubActivity.shared.asleep = true } })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { GitHubActivity.shared.asleep = false } })
        Task { await setup() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        status = "Off"
    }

    private func setup() async {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        ghPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let gh = ghPath else { available = false; status = "GitHub CLI (gh) not found, so this is off"; return }
        // `gh api user` only returns the account name; the token never leaves gh.
        let (code, out) = await Self.run(gh, ["api", "user", "--jq", ".login"])
        let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == 0, !name.isEmpty else { available = false; status = "gh is not logged in, so this is off"; return }
        login = name
        available = true
        status = "Watching @\(name) every 2 min"
        poll()
        let t = Timer(timeInterval: 120, repeats: true) { _ in MainActor.assumeIsolated { GitHubActivity.shared.poll() } }
        t.tolerance = 20
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Fallback for pushes the events feed is slow to show (it can lag by minutes): the
    /// account's most recently pushed repos, compared with the last pushed_at seen.
    private let pushedKey = "IslandGitHubPushedAt"
    private func pollRepos(_ gh: String) {
        Task {
            let (code, out) = await Self.run(gh, ["api", "/user/repos?sort=pushed&per_page=10", "--jq", ".[] | [.name, .pushed_at] | @tsv"])
            guard code == 0 else { return }
            var seen = (Env.defaults.dictionary(forKey: pushedKey) as? [String: String]) ?? [:]
            let first = seen.isEmpty
            for line in out.split(whereSeparator: \.isNewline) {
                let f = line.split(separator: "\t").map(String.init)
                guard f.count == 2 else { continue }
                if !first, let old = seen[f[0]], f[1] > old {   // ISO 8601 strings compare in time order
                    GitCelebrations.shared.push(repo: f[0], detail: "on GitHub", source: .github)
                }
                seen[f[0]] = f[1]
            }
            Env.defaults.set(seen, forKey: pushedKey)
        }
    }

    private func poll() {
        guard !asleep, let gh = ghPath, let user = login else { return }
        pollRepos(gh)
        var args = ["api", "--include", "/users/\(user)/events?per_page=30"]
        if let e = etag { args += ["-H", "If-None-Match: \(e)"] }
        Task {
            let (_, out) = await Self.run(gh, args)
            // --include prints status line + headers, a blank line, then the body.
            guard let split = out.range(of: "\r\n\r\n") ?? out.range(of: "\n\n") else { return }
            let head = String(out[..<split.lowerBound])
            let body = String(out[split.upperBound...])
            if head.contains(" 304") { return } // unchanged, costs no rate limit
            for line in head.split(whereSeparator: \.isNewline) where line.lowercased().hasPrefix("etag:") {
                etag = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
            guard let data = body.data(using: .utf8), let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            handle(events)
        }
    }

    private func handle(_ events: [[String: Any]]) {
        let lastID = Env.defaults.string(forKey: lastIDKey)
        guard let newest = events.first?["id"] as? String else { return }
        defer { Env.defaults.set(newest, forKey: lastIDKey) }
        // First run: remember where we are, celebrate nothing old.
        guard let last = lastID else { return }
        let fresh = events.prefix { ($0["id"] as? String) != last }.reversed()
        guard AppSettings.shared.prefs.celebrations else { return }
        for e in fresh.prefix(3) {
            let type = e["type"] as? String ?? ""
            let repo = (e["repo"] as? [String: Any])?["name"] as? String ?? ""
            let short = repo.split(separator: "/").last.map(String.init) ?? repo
            let payload = e["payload"] as? [String: Any] ?? [:]
            switch type {
            case "PushEvent":
                // Don't double-celebrate a push Glance already showed from Claude Code.
                if let t = recentLocalPush[short], Date().timeIntervalSince(t) < 600 { continue }
                // GitHub's events feed may leave out "commits" and "size" (UAT, 16 Oct): then the
                // count is unknown (0) and the celebration says only where it was pushed.
                let commits = payload["commits"] as? [[String: Any]] ?? []
                let n = max(0, (payload["size"] as? Int) ?? commits.count)
                let branch = (payload["ref"] as? String ?? "").replacingOccurrences(of: "refs/heads/", with: "")
                // Seen locally already (reflog / Claude Code) within 10 min -> skipped there.
                GitCelebrations.shared.push(repo: short, detail: branch.isEmpty ? "on GitHub" : "\(branch) on GitHub", commits: n, source: .github)
            case "PullRequestEvent":
                let action = payload["action"] as? String ?? ""
                let pr = payload["pull_request"] as? [String: Any] ?? [:]
                let title = "#\(pr["number"] as? Int ?? 0) \(pr["title"] as? String ?? "")"
                if action == "closed", (pr["merged"] as? Bool) == true {
                    IslandModel.shared.celebrate(.prMerged(repo: repo, title: String(title.prefix(70))))
                } else if action == "opened" {
                    IslandModel.shared.celebrate(.commit(title: "PR OPENED", repo: repo, message: String(title.prefix(70))))
                }
            case "CreateEvent":
                if (payload["ref_type"] as? String) == "repository" {
                    IslandModel.shared.celebrate(.commit(title: "NEW REPO", repo: repo, message: (payload["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "New repository"))
                }
            default: break
            }
        }
    }

    nonisolated static func run(_ path: String, _ args: [String]) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: (-1, "")); return }
                // Read while it runs, so large output can't fill the pipe and stall gh.
                let d = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(data: d, encoding: .utf8) ?? ""))
            }
        }
    }
}
