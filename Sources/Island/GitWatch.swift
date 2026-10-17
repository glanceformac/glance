import AppKit
import CoreServices

// MARK: wip/cinema-h  GitHub celebrations fix
//
// Commits and pushes are now seen locally and at once: FSEvents on the reflogs
// (.git/logs/HEAD and .git/logs/refs/remotes/...) of repos under ~/Desktop and a few common
// code folders (not ~/Documents: Glance has no Documents access and must not ask for it).
// The GitHub API stays as a fallback for pushes made elsewhere. Every source goes through
// GitCelebrations, which de-duplicates them, collapses bursts into one celebration and, while
// the Context engine holds celebrations back (film, meeting, Prompter), keeps a single tally
// ("12 commits · 3 repos") to show afterwards.

@MainActor
final class GitCelebrations {
    static let shared = GitCelebrations()
    enum Source { case local, claude, github }

    private struct Tally { var commits = 0; var lastMessage = ""; var pushes = 0; var pushDetail = "" }
    private var pending: [String: Tally] = [:]
    private var order: [String] = []
    private var firstPending: Date?
    private var flushItem: DispatchWorkItem?
    private var recentPush: [String: (Date, Source)] = [:]
    private var recentCommit: [String: [(Date, Source)]] = [:]
    /// Quiet time before a burst is shown, and the longest a burst may wait.
    var quiet: TimeInterval = 4, maxWait: TimeInterval = 15

    func commit(repo: String, message: String, source: Source) {
        let now = Date()
        // Claude Code's hook and the reflog both report the same commit: the second one within
        // 30 s (from the other source) is the same commit.
        var list = recentCommit[repo, default: []].filter { now.timeIntervalSince($0.0) < 30 }
        if let i = list.firstIndex(where: { $0.1 != source && $0.1 != .github }) {
            list.remove(at: i); recentCommit[repo] = list
            if !message.isEmpty, pending[repo] != nil { pending[repo]?.lastMessage = message }
            return
        }
        list.append((now, source)); recentCommit[repo] = list
        add(repo) { $0.commits += 1; if !message.isEmpty { $0.lastMessage = message } }
    }

    func push(repo: String, detail: String, commits: Int = 0, source: Source) {
        let now = Date()
        if let (t, s) = recentPush[repo] {
            let window: TimeInterval = (source == .github || s == .github) ? 600 : 30
            if now.timeIntervalSince(t) < window, s != source || source == .github {
                if source != .github { recentPush[repo] = (now, source) }
                if !detail.isEmpty, source != .github, pending[repo] != nil { pending[repo]?.pushDetail = detail }   // keep the better detail
                return
            }
        }
        recentPush[repo] = (now, source)
        add(repo) {
            $0.pushes += 1
            if !detail.isEmpty { $0.pushDetail = detail }
            if source == .github, commits > 0, $0.commits == 0 { $0.commits = commits }   // remote: commits came with the push
        }
    }

    /// Context engine hook: git celebrations held back are folded into the tally instead of
    /// queued one by one. Returns true if the kind was absorbed.
    func absorb(_ k: CelebrationKind) -> Bool {
        switch k {
        case let .commit(title, repo, message):
            if title == "PUSHED" { add(repo) { $0.pushes += 1; $0.pushDetail = message }; return true }
            if title == "COMMIT" || title.hasSuffix(" COMMITS") {
                let n = title == "COMMIT" ? 1 : (Int(title.split(separator: " ").first ?? "") ?? 1)
                add(repo) { $0.commits += n; if !message.isEmpty { $0.lastMessage = message } }
                return true
            }
            return false
        case let .deployed(title, project) where title == "PUSHED":
            add(project) { $0.pushes += 1 }
            return true
        default: return false
        }
    }

    private func add(_ repo: String, _ f: (inout Tally) -> Void) {
        guard AppSettings.shared.prefs.celebrations else { return }
        let key = repo.isEmpty ? "repo" : repo
        if pending[key] == nil { order.append(key) }
        f(&pending[key, default: Tally()])
        if firstPending == nil { firstPending = Date() }
        schedule()
    }

    private func schedule() {
        flushItem?.cancel()
        let waited = Date().timeIntervalSince(firstPending ?? Date())
        let delay = max(0.2, min(quiet, maxWait - waited))
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        flushItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Shows the tally if the context allows it now; otherwise keeps it for `reevaluate()`.
    func flush() {
        flushItem = nil
        guard !pending.isEmpty, let kind = summary() else { return }
        switch IslandContext.shared.celebration(kind) {
        case .later: return                      // kept; IslandContext.reevaluate() calls flush() again
        case .never: break
        case .now:
            if ProcessInfo.processInfo.arguments.contains("--debug") { NSLog("Glance git celebration: %@", "\(kind)") }
            IslandModel.shared.celebrate(kind)
        }
        pending = [:]; order = []; firstPending = nil
    }

    var pendingSummary: String { summary().map { "\($0)" } ?? "none" }

    private func summary() -> CelebrationKind? {
        let repos = order.filter { pending[$0] != nil }
        guard !repos.isEmpty else { return nil }
        let commits = repos.reduce(0) { $0 + pending[$1]!.commits }
        let pushes = repos.reduce(0) { $0 + pending[$1]!.pushes }
        func n(_ v: Int, _ one: String, _ many: String) -> String { v == 1 ? "1 \(one)" : "\(v) \(many)" }
        if repos.count == 1, let r = repos.first, let t = pending[r] {
            if t.pushes > 0 {
                // Never "0 commits" and never an empty line.
                let detail = t.commits > 0 ? n(t.commits, "commit", "commits") + (t.pushDetail.isEmpty ? "" : " · \(t.pushDetail)")
                                           : (t.pushDetail.isEmpty ? "to the remote" : t.pushDetail)
                return .commit(title: "PUSHED", repo: r, message: String(detail.prefix(70)))
            }
            let c = max(1, t.commits)
            return .commit(title: c == 1 ? "COMMIT" : "\(c) COMMITS", repo: r, message: String((t.lastMessage.isEmpty ? n(c, "new commit", "new commits") : t.lastMessage).prefix(70)))
        }
        var parts: [String] = []
        if commits > 0 { parts.append(n(commits, "commit", "commits")) }
        parts.append(n(repos.count, "repo", "repos"))
        if pushes > 0 { parts.append(n(pushes, "push", "pushes")) }
        let title = commits > 0 ? (commits == 1 ? "COMMIT" : "\(commits) COMMITS") : "PUSHED"
        return .commit(title: title, repo: repos.prefix(3).joined(separator: ", ") + (repos.count > 3 ? " +\(repos.count - 3)" : ""),
                       message: parts.joined(separator: " · "))
    }
}

/// FSEvents on reflogs. Directory-level events (not per file), 1.5 s latency, depth-limited,
/// so builds and node_modules churn cost almost nothing. Off unless Settings › Football ›
/// "Celebrate commits in local git folders" is on (off for new installs).
@MainActor
final class GitWatch {
    static let shared = GitWatch()
    private var stream: FSEventStreamRef?
    private var offsets: [String: UInt64] = [:]
    private var roots: [String] = []
    private let started = Date()
    nonisolated static let maxDepth = 4
    nonisolated static let ignored: Set<String> = ["node_modules", ".build", "build", "DerivedData", "Pods", ".Trash", "Library"]
    private(set) var status = "Off"

    static func defaultRoots() -> [String] {
        if Env.isolated {
            // Test instances watch only what they are told to (scratch repos), never your real folders.
            return (ProcessInfo.processInfo.environment["GLANCE_GIT_ROOTS"] ?? "").split(separator: ":").map(String.init)
        }
        let home = NSHomeDirectory()
        // ~/Desktop: Glance already has access. ~/Documents is deliberately not watched (it would
        // ask for Documents access). Plain folders under home need no permission.
        return ([home + "/Desktop"] + ["Developer", "Projects", "code", "src", "repos"].map { home + "/" + $0 })
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    func start() {
        guard stream == nil, Env.isolated || AppSettings.shared.prefs.gitWatchFolders else { return }
        roots = Self.defaultRoots()
        guard !roots.isEmpty else { status = "No folders to watch"; return }
        var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, _, count, paths, _, _ in
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let list = Array(arr.prefix(count))
            MainActor.assumeIsolated { GitWatch.shared.changed(list) }
        }
        guard let s = FSEventStreamCreate(nil, cb, &ctx, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.5,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf)) else {
            status = "Couldn't watch folders"; return
        }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
        status = "Watching commits in " + roots.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
        // Baseline: note the current size of every reflog (off the main thread), so the first
        // commit after launch is already a "new" line.
        let rs = roots
        DispatchQueue.global(qos: .utility).async {
            let found = Self.scan(rs)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                for (p, size) in found where GitWatch.shared.offsets[p] == nil { GitWatch.shared.offsets[p] = size }
            } }
        }
    }

    func stop() {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
        stream = nil
        status = "Off"
    }

    /// Reflog files of every repo within `maxDepth` of the roots, with their sizes.
    nonisolated static func scan(_ roots: [String]) -> [(String, UInt64)] {
        var out: [(String, UInt64)] = []
        let fm = FileManager.default
        func visit(_ dir: String, _ depth: Int) {
            guard depth <= maxDepth, let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
            if items.contains(".git") {
                let g = dir + "/.git"
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: g, isDirectory: &isDir), isDir.boolValue { out += reflogs(gitDir: g) }
            }
            for name in items where !name.hasPrefix(".") && !ignored.contains(name) {
                let p = dir + "/" + name
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue, !p.hasSuffix(".app") { visit(p, depth + 1) }
            }
        }
        for r in roots { visit(r, 0) }
        return out
    }

    nonisolated static func reflogs(gitDir g: String) -> [(String, UInt64)] {
        let fm = FileManager.default
        var files = [g + "/logs/HEAD"]
        let remotes = g + "/logs/refs/remotes"
        if let e = fm.enumerator(atPath: remotes) { for case let f as String in e { files.append(remotes + "/" + f) } }
        return files.compactMap { f in
            guard let a = try? fm.attributesOfItem(atPath: f), (a[.type] as? FileAttributeType) == .typeRegular else { return nil }
            return (f, (a[.size] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    private func changed(_ paths: [String]) {
        var gitDirs = Set<String>()
        for p in paths {
            guard let r = p.range(of: "/.git/logs") else { continue }
            let repo = String(p[..<r.lowerBound])
            if p.contains("/.git/worktrees/") { continue }               // agent worktrees: noise
            guard let root = roots.first(where: { repo.hasPrefix($0) }) else { continue }
            let rel = repo.dropFirst(root.count).split(separator: "/")
            if rel.count > Self.maxDepth || rel.contains(where: { Self.ignored.contains(String($0)) }) { continue }
            gitDirs.insert(repo + "/.git")
        }
        for g in gitDirs { read(gitDir: g) }
    }

    private func read(gitDir g: String) {
        let repoPath = (g as NSString).deletingLastPathComponent
        let repo = (repoPath as NSString).lastPathComponent
        for (file, size) in Self.reflogs(gitDir: g) {
            var from = offsets[file]
            if from == nil {
                // A reflog Glance hasn't seen: new since launch (git init / first push) -> read it all.
                let created = (try? FileManager.default.attributesOfItem(atPath: file)[.creationDate] as? Date) ?? .distantPast
                from = created > started ? 0 : size
            }
            guard var start = from else { continue }
            if size < start { start = 0 }                                 // reflog rewritten (gc / expire)
            offsets[file] = size
            guard size > start, let h = FileHandle(forReadingAtPath: file) else { continue }
            defer { try? h.close() }
            try? h.seek(toOffset: start)
            guard let data = try? h.read(upToCount: Int(min(size - start, 256 * 1024))), let text = String(data: data, encoding: .utf8) else { continue }
            let remoteRef: String? = file.range(of: "/logs/refs/remotes/").map { String(file[$0.upperBound...]) }
            for line in text.split(whereSeparator: \.isNewline) {
                guard let tab = line.firstIndex(of: "\t") else { continue }
                let msg = String(line[line.index(after: tab)...])
                if let ref = remoteRef {
                    if msg.hasPrefix("update by push") {
                        let bits = ref.split(separator: "/", maxSplits: 1).map(String.init)   // origin/main
                        GitCelebrations.shared.push(repo: repo, detail: bits.count == 2 ? "\(bits[1]) to \(bits[0])" : ref, source: .local)
                    }
                } else if msg.hasPrefix("commit") || msg.hasPrefix("cherry-pick") {
                    // "commit: msg", "commit (initial): msg", "commit (amend): msg", "commit (merge): msg"
                    let text = msg.range(of: ": ").map { String(msg[$0.upperBound...]) } ?? ""
                    GitCelebrations.shared.commit(repo: repo, message: text, source: .local)
                }
            }
        }
    }
}
