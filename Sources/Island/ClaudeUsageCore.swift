// MARK: feat/claude-dev
// Claude Code usage: transcript scanner and maths. Foundation only (no UI), so it can also be
// compiled into a small command-line check.
//
// Privacy rules:
//  * Reads ONLY `~/.claude/projects/**/*.jsonl` (session transcripts and subagent transcripts).
//    Never opens ~/.claude/.credentials*, the keychain, or any other file.
//  * Keeps only numbers: timestamps, token counts, model id, a 64-bit hash of the message id.
//    No message text, tool input or output is stored, logged or printed.

import Foundation

/// One API call (assistant message) or one user prompt.
struct UsageRecord: Codable, Sendable, Equatable {
    var t: Double            // seconds since 1970
    var h: Int64             // FNV-1a hash of the message id (dedupe across resumed sessions)
    var m: String            // model id ("" for prompts)
    var i: Int = 0           // input tokens (uncached)
    var o: Int = 0           // output tokens
    var w5: Int = 0          // cache write, 5 minute
    var w1: Int = 0          // cache write, 1 hour
    var r: Int = 0           // cache read
    var f: Bool = false      // fast mode
    var p: Bool = false      // true = a user prompt (a "turn"), not an API call

    var counted: Int { i + o + w5 + w1 }   // tokens that count towards the budget (cache reads excluded)
}

struct FileCursor: Codable, Sendable { var offset: UInt64; var size: UInt64; var inode: UInt64 }

/// Persistent scan state: per-file offsets plus the last 8 days of records.
struct UsageCache: Codable, Sendable {
    var version = 2
    var files: [String: FileCursor] = [:]
    var records: [UsageRecord] = []
}

/// API list prices in USD per million tokens. Cache writes are 1.25x (5 min) and 2x (1 h) of
/// input; cache reads have their own price. Source: Anthropic model table (cached 2026-10-06).
enum ModelPrice {
    struct Rate: Sendable { let input: Double; let output: Double; let cacheRead: Double }

    static func rate(for model: String) -> Rate {
        let m = model.lowercased()
        switch true {
        case m.hasPrefix("claude-fable-5-1"), m.hasPrefix("claude-mythos-5-1"): return Rate(input: 10, output: 50, cacheRead: 0.25)
        case m.contains("fable"), m.contains("mythos"): return Rate(input: 10, output: 50, cacheRead: 1.0)
        case m.hasPrefix("claude-opus-5-5"): return Rate(input: 4, output: 20, cacheRead: 0.20)
        case m.contains("opus"): return Rate(input: 5, output: 25, cacheRead: 0.50)
        case m.hasPrefix("claude-sonnet-5"): return Rate(input: 2, output: 10, cacheRead: 0.20)
        case m.contains("sonnet"): return Rate(input: 3, output: 15, cacheRead: 0.30)
        case m.hasPrefix("claude-haiku-5"): return Rate(input: 0.10, output: 0.50, cacheRead: 0.01)
        case m.contains("haiku"): return Rate(input: 1, output: 5, cacheRead: 0.10)
        default: return Rate(input: 4, output: 20, cacheRead: 0.20)   // unknown: priced like the default model
        }
    }

    static func cost(_ r: UsageRecord) -> Double {
        guard !r.p else { return 0 }
        let k = rate(for: r.m)
        let usd = (Double(r.i) * k.input + Double(r.o) * k.output + Double(r.w5) * k.input * 1.25
                   + Double(r.w1) * k.input * 2 + Double(r.r) * k.cacheRead) / 1_000_000
        return r.f ? usd * 2 : usd
    }
}

/// Totals for a time window.
struct UsageTotals: Sendable, Equatable {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    var calls = 0, prompts = 0
    var cost = 0.0
    var counted: Int { input + output + cacheWrite }

    mutating func add(_ r: UsageRecord) {
        if r.p { prompts += 1; return }
        input += r.i; output += r.o; cacheWrite += r.w5 + r.w1; cacheRead += r.r
        calls += 1
        cost += ModelPrice.cost(r)
    }

    static func of(_ records: [UsageRecord], from: Double, to: Double = .infinity) -> UsageTotals {
        var t = UsageTotals()
        for r in records where r.t >= from && r.t < to { t.add(r) }
        return t
    }
}

enum UsageMath {
    static let block: Double = 5 * 3600

    /// Start of the current 5-hour block, or nil if no block is active. A block starts at the
    /// first activity after the previous block ended, rounded down to the hour.
    static func currentBlockStart(_ records: [UsageRecord], now: Double) -> Double? {
        var start: Double?
        for t in records.map(\.t).sorted() where t <= now {
            if let s = start, t < s + block { continue }
            start = floor(t / 3600) * 3600
        }
        guard let s = start, now < s + block else { return nil }
        return s
    }

    /// Most recent weekly reset before `now`. weekday: 1 = Sunday ... 7 = Saturday; 0 = rolling 7 days.
    static func weekStart(now: Double, weekday: Int, hour: Int, calendar: Calendar = .current) -> Double {
        guard (1...7).contains(weekday) else { return now - 7 * 86400 }
        let date = Date(timeIntervalSince1970: now)
        var c = DateComponents(); c.weekday = weekday; c.hour = hour; c.minute = 0; c.second = 0
        let next = calendar.nextDate(after: date, matching: c, matchingPolicy: .nextTime) ?? date
        return next.timeIntervalSince1970 - 7 * 86400
    }

    /// Straight-line projection of `used` at the end of a window.
    static func projection(used: Double, start: Double, end: Double, now: Double) -> Double? {
        let elapsed = now - start
        guard elapsed >= 600, end > start else { return nil }   // need 10 minutes of data
        return used / elapsed * (end - start)
    }
}

/// Incremental scanner. Not thread-safe: use it from one serial queue.
final class TranscriptScanner {
    let root: URL
    private(set) var cache: UsageCache
    private var seen: Set<Int64> = []
    static let keepSeconds: Double = 8 * 86400

    init(root: URL, cache: UsageCache = UsageCache()) {
        self.root = root
        self.cache = cache
        seen = Set(cache.records.map(\.h))
    }

    /// Transcript files: <project>/<session>.jsonl and <project>/<session>/subagents/*.jsonl.
    func transcriptFiles() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        for p in projects {
            guard let items = try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for it in items {
                if it.pathExtension == "jsonl" { out.append(it); continue }
                let sub = it.appendingPathComponent("subagents", isDirectory: true)
                if let subs = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    out.append(contentsOf: subs.filter { $0.pathExtension == "jsonl" })
                }
            }
        }
        // Belt and braces: never touch anything that looks like a credentials file.
        return out.filter { !$0.lastPathComponent.lowercased().contains("credential") }
    }

    struct Stats: Sendable { var files = 0; var filesRead = 0; var bytesRead: UInt64 = 0; var newRecords = 0; var seconds = 0.0 }

    /// Reads new bytes from every recently modified transcript. Returns what changed.
    @discardableResult
    func scan(now: Double = Date().timeIntervalSince1970) -> Stats {
        let t0 = Date()
        var stats = Stats()
        let cutoff = now - Self.keepSeconds
        let files = transcriptFiles()
        stats.files = files.count
        var live: Set<String> = []
        for url in files {
            let path = url.path
            var st = stat()
            guard stat(path, &st) == 0 else { continue }
            live.insert(path)
            let size = UInt64(st.st_size), inode = UInt64(st.st_ino)
            let mtime = Double(st.st_mtimespec.tv_sec)
            var cur = cache.files[path] ?? FileCursor(offset: 0, size: 0, inode: inode)
            if cur.inode != inode || size < cur.offset { cur = FileCursor(offset: 0, size: 0, inode: inode) }  // replaced or truncated
            if size == cur.offset { cache.files[path] = cur; continue }
            if mtime < cutoff { cur.offset = size; cur.size = size; cache.files[path] = cur; continue } // nothing recent in it
            let read = readNew(path: path, from: cur.offset, to: size, cutoff: cutoff, stats: &stats)
            cur.offset += read
            cur.size = size
            cache.files[path] = cur
            stats.filesRead += 1
        }
        cache.files = cache.files.filter { live.contains($0.key) }
        cache.records.removeAll { $0.t < cutoff }
        cache.records.sort { $0.t < $1.t }
        seen = Set(cache.records.map(\.h))
        stats.seconds = Date().timeIntervalSince(t0)
        return stats
    }

    /// Reads complete lines from [from, to). Returns the number of bytes consumed (up to the last newline).
    private func readNew(path: String, from: UInt64, to: UInt64, cutoff: Double, stats: inout Stats) -> UInt64 {
        guard let fh = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: from) } catch { return 0 }
        var carry = Data()
        let chunkSize = 8 << 20
        var remaining = to - from
        while remaining > 0 {
            let want = Int(min(UInt64(chunkSize), remaining))
            // Read and parse inside one pool so Foundation's temporary buffers are freed per chunk.
            let ok: Bool = autoreleasepool {
                guard let chunk = try? fh.read(upToCount: want), !chunk.isEmpty else { return false }
                remaining -= UInt64(chunk.count)
                stats.bytesRead += UInt64(chunk.count)
                var buf = carry
                buf.append(chunk)
                let used = processLines(buf, cutoff: cutoff, stats: &stats)
                carry = used < buf.count ? Data(buf[used...]) : Data()
                return true
            }
            if !ok { break }
            // Guard against a pathological single line larger than 256 MB.
            if carry.count > 256 << 20 { carry = Data() }
        }
        // Bytes consumed = everything read minus the unfinished tail.
        return (to - from - remaining) - UInt64(carry.count)
    }

    /// Processes every complete line in `buf`; returns the index just past the last newline.
    private func processLines(_ buf: Data, cutoff: Double, stats: inout Stats) -> Int {
        var end = 0
        buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let n = raw.count
            var start = 0
            while start < n {
                guard let nlPtr = memchr(base + start, 0x0A, n - start) else { break }
                let nl = base.distance(to: UnsafeRawPointer(nlPtr))
                let len = nl - start
                if len > 2 { autoreleasepool { handleLine(UnsafeRawBufferPointer(start: base + start, count: len), cutoff: cutoff, stats: &stats) } }
                start = nl + 1
                end = start
            }
        }
        return end
    }

    private static let kAssistant = Array(#""type":"assistant""#.utf8)
    private static let kUsage = Array(#""usage":{"#.utf8)
    private static let kUser = Array(#""type":"user""#.utf8)
    private static let kToolUse = Array(#""tool_use_id""#.utf8)

    private static func contains(_ line: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        needle.withUnsafeBytes { nb in memmem(line.baseAddress!, line.count, nb.baseAddress!, nb.count) != nil }
    }

    private func handleLine(_ line: UnsafeRawBufferPointer, cutoff: Double, stats: inout Stats) {
        // User lines (the big ones: tool results) carry their top-level "type" near the start,
        // so they are recognised without scanning the whole line.
        let head = UnsafeRawBufferPointer(rebasing: line[0..<min(line.count, 1024)])
        let userLine = Self.contains(head, Self.kUser)
        let isAssistant = !userLine && Self.contains(line, Self.kUsage) && Self.contains(line, Self.kAssistant)
        // A typed prompt: a user line with no tool result, and not huge (pasted logs aside).
        let isPrompt = userLine && line.count < 2_000_000 && !Self.contains(line, Self.kToolUse)
        guard isAssistant || isPrompt else { return }
        let data = Data(bytes: line.baseAddress!, count: line.count)
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        guard let ts = o["timestamp"] as? String, let t = Self.parseTime(ts), t >= cutoff else { return }
        if isAssistant {
            guard o["type"] as? String == "assistant", let msg = o["message"] as? [String: Any],
                  let u = msg["usage"] as? [String: Any] else { return }
            let model = msg["model"] as? String ?? ""
            if model == "<synthetic>" { return }
            let key = (msg["id"] as? String ?? "") + ":" + (o["requestId"] as? String ?? (o["uuid"] as? String ?? ""))
            let h = Self.fnv(key)
            guard !seen.contains(h) else { return }
            func int(_ d: [String: Any]?, _ k: String) -> Int { (d?[k] as? NSNumber)?.intValue ?? 0 }
            let cc = u["cache_creation"] as? [String: Any]
            var w5 = int(cc, "ephemeral_5m_input_tokens"), w1 = int(cc, "ephemeral_1h_input_tokens")
            let wAll = int(u, "cache_creation_input_tokens")
            if w5 + w1 == 0 { w5 = wAll }
            let rec = UsageRecord(t: t, h: h, m: model, i: int(u, "input_tokens"), o: int(u, "output_tokens"),
                                  w5: w5, w1: w1, r: int(u, "cache_read_input_tokens"), f: (u["speed"] as? String) == "fast")
            seen.insert(h)
            cache.records.append(rec)
            stats.newRecords += 1
        } else {
            guard o["type"] as? String == "user", (o["isMeta"] as? Bool) != true, (o["isSidechain"] as? Bool) != true,
                  (o["isCompactSummary"] as? Bool) != true, let msg = o["message"] as? [String: Any] else { return }
            var text = ""
            if let s = msg["content"] as? String { text = s }
            else if let arr = msg["content"] as? [[String: Any]] {
                if arr.contains(where: { ($0["type"] as? String) == "tool_result" }) { return }
                text = arr.compactMap { $0["text"] as? String }.first ?? (arr.isEmpty ? "" : "[attachment]")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("<local-command") || trimmed.hasPrefix("<command-") || trimmed.hasPrefix("[Request interrupted") { return }
            let h = Self.fnv("p:" + (o["uuid"] as? String ?? ts))
            guard !seen.contains(h) else { return }
            seen.insert(h)
            cache.records.append(UsageRecord(t: t, h: h, m: "", p: true))
            stats.newRecords += 1
        }
    }

    static func fnv(_ s: String) -> Int64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return Int64(bitPattern: h)
    }

    /// "2026-10-11T10:44:48.402Z" -> seconds since 1970 (fast path, no formatter).
    static func parseTime(_ s: String) -> Double? {
        let u = Array(s.utf8)
        guard u.count >= 20, u[4] == 45, u[7] == 45, u[10] == 84 else { return nil }
        func num(_ a: Int, _ b: Int) -> Int? {
            var v = 0
            for i in a..<b { let c = Int(u[i]) - 48; guard c >= 0, c <= 9 else { return nil }; v = v * 10 + c }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10), let hh = num(11, 13), let mi = num(14, 16), let ss = num(17, 19) else { return nil }
        var frac = 0.0
        var i = 19
        if i < u.count, u[i] == 46 {
            i += 1; var scale = 0.1
            while i < u.count, u[i] >= 48, u[i] <= 57 { frac += Double(u[i] - 48) * scale; scale /= 10; i += 1 }
        }
        // Days from civil (Howard Hinnant), UTC. Transcripts use "Z".
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Double(days * 86400 + hh * 3600 + mi * 60 + ss) + frac
    }
}
