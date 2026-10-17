// MARK: feat/claude-dev
// Claude Code usage tracker: reads local transcripts incrementally on a background queue and
// publishes totals for the current 5-hour session, the week and today.
//
// Refresh policy (performance budget):
//  * every 60 s only while a usage view is on screen or a threshold is near (>= 70%);
//  * otherwise a cheap incremental check every 15 minutes, plus one a few seconds after each
//    Claude Code "Stop" hook event (if the hooks are installed);
//  * nothing while the screen sleeps; nothing at all when the feature is off.

import AppKit
import Observation
import SwiftUI

struct UsageWindow: Equatable, Sendable {
    var totals = UsageTotals()
    var start: Double = 0
    var end: Double? = nil            // nil: rolling window
    var fraction: Double = 0          // used / budget (estimate)
    var projected: Double? = nil      // projected fraction at reset
    var active = false
}

struct UsageSnapshot: Sendable {
    var session = UsageWindow()
    var week = UsageWindow()
    var today = UsageTotals()
    var recordCount = 0
    var stats = TranscriptScanner.Stats()
}

private final class ScannerBox: @unchecked Sendable {
    var scanner: TranscriptScanner?
    var cacheURL: URL?
    var lastSavedCount = -1
}

@Observable @MainActor
final class ClaudeUsage {
    static let shared = ClaudeUsage()

    private(set) var snapshot = UsageSnapshot()
    private(set) var lastUpdated: Date?
    private(set) var scanning = false
    private(set) var status = "Not read yet"
    private(set) var running = false

    @ObservationIgnored private let queue = DispatchQueue(label: "island.claude.usage", qos: .utility)
    @ObservationIgnored private let box = ScannerBox()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var timerInterval: TimeInterval = 0
    @ObservationIgnored private var viewers: Set<String> = []
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var firedPeeks: Set<String> = []
    @ObservationIgnored private var debounce: Task<Void, Never>?
    /// Debug/snapshots: a fixed snapshot that is never overwritten by a scan.
    @ObservationIgnored var demo = false

    private var prefs: DevPrefs { AppSettings.shared.prefs.dev }

    nonisolated static var transcriptRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Cache of offsets and numbers only. Isolated test instances keep theirs next to the test socket.
    nonisolated static var cacheDirectory: URL {
        if let s = Env.testSocket { return URL(fileURLWithPath: (s as NSString).deletingLastPathComponent, isDirectory: true) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Glance", isDirectory: true)
    }

    // MARK: Lifecycle

    func start() {
        guard prefs.usageEnabled, !running else { return }
        running = true
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ClaudeUsage.shared.asleep = true; ClaudeUsage.shared.reschedule() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ClaudeUsage.shared.asleep = false; ClaudeUsage.shared.reschedule(); ClaudeUsage.shared.refresh() }
        })
        firedPeeks = Self.loadFired()
        refresh()
        reschedule()
    }

    func stop() {
        running = false
        timer?.invalidate(); timer = nil; timerInterval = 0
        debounce?.cancel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        // Drop the in-memory scanner too; a disabled feature keeps nothing around.
        let b = box
        queue.async { b.scanner = nil }
    }

    /// Usage views call this on appear / disappear.
    func setVisible(_ id: String, _ visible: Bool) {
        let was = !viewers.isEmpty
        if visible { viewers.insert(id) } else { viewers.remove(id) }
        if visible && !was {
            // Fresh numbers as soon as a view opens, if the last read is over 20 s old.
            if (lastUpdated.map { Date().timeIntervalSince($0) > 20 } ?? true) { refresh() }
        }
        reschedule()
    }

    /// Called after a Claude Code turn ends (Stop hook).
    func turnEnded() {
        guard running else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private var nearThreshold: Bool {
        let s = snapshot.session, w = snapshot.week
        func near(_ x: UsageWindow) -> Bool { x.active && x.fraction >= 0.70 && x.fraction < 1.0 }
        return near(s) || near(w)
    }

    private func reschedule() {
        guard running, !asleep else {
            timer?.invalidate(); timer = nil; timerInterval = 0
            return
        }
        let want: TimeInterval = (!viewers.isEmpty || nearThreshold) ? 60 : 900
        guard want != timerInterval else { return }
        timer?.invalidate()
        timerInterval = want
        let t = Timer(timeInterval: want, repeats: true) { _ in MainActor.assumeIsolated { ClaudeUsage.shared.refresh() } }
        t.tolerance = want * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Scanning

    func refresh() {
        guard running, !scanning, !demo else { return }
        scanning = true
        if lastUpdated == nil { status = "Reading Claude Code transcripts…" }
        let p = prefs
        let b = box
        let root = Self.transcriptRoot
        let cacheURL = Self.cacheDirectory.appendingPathComponent("claude-usage-cache.json")
        queue.async {
            let snap = Self.scanOnQueue(box: b, root: root, cacheURL: cacheURL, prefs: p)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = ClaudeUsage.shared
                    me.scanning = false
                    guard me.running, !me.demo else { return }
                    me.apply(snap)
                }
            }
        }
    }

    /// Recomputes windows from the scanner's records (after a budget change, no file reads).
    func recompute() {
        guard running, !demo else { return }
        let p = prefs, b = box
        queue.async {
            guard let s = b.scanner else { return }
            let snap = Self.compute(records: s.cache.records, prefs: p, now: Date().timeIntervalSince1970)
            DispatchQueue.main.async { MainActor.assumeIsolated { if !ClaudeUsage.shared.demo { ClaudeUsage.shared.apply(snap, peeks: false) } } }
        }
    }

    nonisolated private static func scanOnQueue(box b: ScannerBox, root: URL, cacheURL: URL, prefs: DevPrefs) -> UsageSnapshot {
        if b.scanner == nil {
            var cache = UsageCache()
            if let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(UsageCache.self, from: d), c.version == UsageCache().version {
                cache = c
            }
            b.scanner = TranscriptScanner(root: root, cache: cache)
            b.cacheURL = cacheURL
        }
        guard let s = b.scanner else { return UsageSnapshot() }
        let stats = s.scan()
        if stats.newRecords > 0 || b.lastSavedCount < 0 || stats.bytesRead > 0 {
            if let d = try? JSONEncoder().encode(s.cache) {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                try? d.write(to: cacheURL, options: .atomic)
                chmod(cacheURL.path, 0o600)
                b.lastSavedCount = s.cache.records.count
            }
        }
        var snap = compute(records: s.cache.records, prefs: prefs, now: Date().timeIntervalSince1970)
        snap.stats = stats
        return snap
    }

    nonisolated static func compute(records: [UsageRecord], prefs: DevPrefs, now: Double) -> UsageSnapshot {
        var snap = UsageSnapshot()
        snap.recordCount = records.count
        func frac(_ t: UsageTotals, tokens: Int, prompts: Int) -> Double {
            prefs.metric == .tokens ? Double(t.counted) / Double(max(tokens, 1)) : Double(t.prompts) / Double(max(prompts, 1))
        }
        func used(_ t: UsageTotals) -> Double { prefs.metric == .tokens ? Double(t.counted) : Double(t.prompts) }

        if let start = UsageMath.currentBlockStart(records, now: now) {
            var w = UsageWindow(start: start, end: start + UsageMath.block, active: true)
            w.totals = UsageTotals.of(records, from: start)
            w.fraction = frac(w.totals, tokens: prefs.sessionTokenBudget, prompts: prefs.sessionPromptBudget)
            let budget = Double(max(prefs.metric == .tokens ? prefs.sessionTokenBudget : prefs.sessionPromptBudget, 1))
            w.projected = UsageMath.projection(used: used(w.totals), start: start, end: start + UsageMath.block, now: now).map { $0 / budget }
            snap.session = w
        }
        let ws = UsageMath.weekStart(now: now, weekday: prefs.weekResetWeekday, hour: prefs.weekResetHour)
        var w = UsageWindow(start: ws, end: prefs.weekResetWeekday == 0 ? nil : ws + 7 * 86400, active: true)
        w.totals = UsageTotals.of(records, from: ws)
        w.fraction = frac(w.totals, tokens: prefs.weekTokenBudget, prompts: prefs.weekPromptBudget)
        if let end = w.end {
            let budget = Double(max(prefs.metric == .tokens ? prefs.weekTokenBudget : prefs.weekPromptBudget, 1))
            w.projected = UsageMath.projection(used: used(w.totals), start: ws, end: end, now: now).map { $0 / budget }
        }
        snap.week = w
        let today = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        snap.today = UsageTotals.of(records, from: today)
        return snap
    }

    private func apply(_ snap: UsageSnapshot, peeks: Bool = true) {
        var s = snap
        if s.stats.files == 0 && snap.stats.seconds == 0 { s.stats = snapshot.stats }
        snapshot = s
        lastUpdated = Date()
        status = s.recordCount == 0 ? "No Claude Code activity in the last 8 days" : "Updated"
        if peeks { checkThresholds() }
        reschedule()
    }

    // MARK: Threshold peeks (80% and 95%, once per window)

    private func checkThresholds() {
        guard prefs.usagePeeks else { return }
        let checks: [(String, UsageWindow)] = [("session", snapshot.session), ("week", snapshot.week)]
        for (name, w) in checks where w.active {
            for level in [0.95, 0.80] where w.fraction >= level {
                // Rolling week: key by day so it can fire again on another day.
                let anchor = w.end == nil ? floor(Date().timeIntervalSince1970 / 86400) : w.start
                let key = "\(name)-\(Int(anchor))-\(Int(level * 100))"
                if firedPeeks.contains(key) { break }
                firedPeeks.insert(key)
                // Crossing 95% also marks 80% for this window, so only one peek shows.
                if level == 0.95 { firedPeeks.insert("\(name)-\(Int(anchor))-80") }
                Self.saveFired(firedPeeks)
                showPeek(name: name, window: w, level: level)
                break
            }
        }
    }

    func showPeek(name: String, window w: UsageWindow, level: Double) {
        let pct = Int((w.fraction * 100).rounded())
        var sub = "est."
        if let end = w.end { sub = Self.short(end - Date().timeIntervalSince1970) }
        IslandModel.shared.enqueue(Peek(symbol: level >= 0.95 ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.67percent",
                                        title: name == "session" ? "Claude \(pct)%" : "Claude week \(pct)%", subtitle: sub,
                                        tint: level >= 0.95 ? Color(red: 1, green: 0.35, blue: 0.3) : .orange, duration: 4))
    }

    nonisolated private static var firedURL: URL { cacheDirectory.appendingPathComponent("claude-usage-peeks.json") }
    private static func loadFired() -> Set<String> {
        guard let d = try? Data(contentsOf: firedURL), let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(a)
    }
    private static func saveFired(_ s: Set<String>) {
        // Keep only recent keys (they embed the window start).
        let cutoff = Date().timeIntervalSince1970 - 9 * 86400
        let keep = s.filter { k in
            let parts = k.split(separator: "-"); guard parts.count == 3, let t = Double(parts[1]) else { return false }
            return t > 100_000 ? t > cutoff : t * 86400 > cutoff
        }
        if let d = try? JSONEncoder().encode(Array(keep).sorted()) { try? d.write(to: firedURL, options: .atomic) }
    }

    // MARK: Formatting

    static func short(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s >= 86400 { return "\(s / 86400)d \((s % 86400) / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(max(1, s / 60))m"
    }

    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000_000 { return String(format: "%.2fB", d / 1_000_000_000) }
        if d >= 1_000_000 { return String(format: d >= 100_000_000 ? "%.0fM" : "%.1fM", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.1fk", d / 1_000) }
        return "\(n)"
    }

    static func dollars(_ x: Double) -> String { x >= 100 ? String(format: "$%.0f", x) : String(format: "$%.2f", x) }

    // MARK: Debug

    /// Debug/snapshots only: fixed numbers, no file access.
    func debugDemo(sessionFraction: Double, weekFraction: Double) {
        demo = true
        let now = Date().timeIntervalSince1970
        let p = prefs
        var s = UsageWindow(start: floor(now / 3600) * 3600 - 3 * 3600, end: nil, active: true)
        s.end = s.start + UsageMath.block
        s.totals = UsageTotals(input: 1_520, output: 66_200, cacheWrite: Int(Double(p.sessionTokenBudget) * sessionFraction) - 67_720,
                               cacheRead: 193_400_000, calls: 753, prompts: 38, cost: 62.75)
        s.fraction = sessionFraction
        s.projected = sessionFraction * 5 / 3.2
        var w = UsageWindow(start: now - 7 * 86400, end: nil, active: true)
        w.totals = UsageTotals(input: 88_400, output: 2_497_000, cacheWrite: Int(Double(p.weekTokenBudget) * weekFraction) - 2_585_400,
                               cacheRead: 2_368_700_000, calls: 9_112, prompts: 1_020, cost: 846.54)
        w.fraction = weekFraction
        snapshot = UsageSnapshot(session: s, week: w,
                                 today: UsageTotals(input: 1_878, output: 106_880, cacheWrite: 21_594_672, cacheRead: 258_453_769, calls: 917, prompts: 59, cost: 163.89),
                                 recordCount: 10_454)
        lastUpdated = Date()
        status = "Demo data"
        checkThresholds()
    }

    func debugEndDemo() { demo = false; refresh() }
}
