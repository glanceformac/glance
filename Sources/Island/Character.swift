import AppKit
import SwiftUI
import Observation

// MARK: - Notch character
//
// A small companion that lives in the island and reacts to what the Mac is doing (music, video,
// Claude Code, the Shelf, the calendar, being idle). The art comes from a "character pack": a
// folder with a manifest.json and its images / videos, loaded at runtime from
// ~/Library/Application Support/Glance/Characters/<pack>/. Glance ships one original pack drawn
// in code (Mochi); other packs are personal and never part of the app bundle.

enum CharacterState: String, CaseIterable, Identifiable, Codable {
    case idle, sleeping, music, movie, thinking, approval, finished, shelf, meeting
    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: "Idle"
        case .sleeping: "Sleeping"
        case .music: "Music playing"
        case .movie: "Movie playing"
        case .thinking: "Claude thinking"
        case .approval: "Claude needs approval"
        case .finished: "Claude finished"
        case .shelf: "File dropped on Shelf"
        case .meeting: "Meeting soon"
        }
    }

    var detail: String {
        switch self {
        case .idle: "Breathing slowly; every few seconds a little snack moment."
        case .sleeping: "After 10 minutes without mouse or keyboard input. Wakes when you come back."
        case .music: "Something is playing (not a video): runs or bobs along with it."
        case .movie: "Cinema mode or a full-screen video: a puff of smoke, then hidden so it never pulls focus."
        case .thinking: "Claude Code is working (prompt sent, tools running)."
        case .approval: "Claude Code is waiting for Allow or Deny. The usual buttons stay as they are."
        case .finished: "Claude Code finished: a thumbs-up and a hop, then back to idle."
        case .shelf: "A file landed on the Shelf: caught with a thumbs-up."
        case .meeting: "A calendar event starts within 5 minutes: a little watch badge."
        }
    }

    /// Highest first: approval > finished > thinking > movie > shelf drop > meeting > music > sleeping > idle.
    static let priority: [CharacterState] = [.approval, .finished, .thinking, .movie, .shelf, .meeting, .music, .sleeping, .idle]
}

/// Which signals are true right now. `resolve` is pure so it can be checked headless.
struct CharacterSignals: Equatable {
    var approval = false
    var finished = false
    var thinking = false
    var movie = false
    var shelf = false
    var meeting = false
    var music = false
    var sleeping = false

    func has(_ s: CharacterState) -> Bool {
        switch s {
        case .approval: approval
        case .finished: finished
        case .thinking: thinking
        case .movie: movie
        case .shelf: shelf
        case .meeting: meeting
        case .music: music
        case .sleeping: sleeping
        case .idle: true
        }
    }

    var resolved: CharacterState { CharacterState.priority.first { has($0) } ?? .idle }
}

/// Everything a rig needs to draw one moment (the island, the notch, the Touch Bar and the
/// Settings preview all use the same value, so they show the same pose).
struct CharacterFrame: Equatable {
    var state: CharacterState = .idle
    /// Idle only: the snack moment (the pack's "idleAlt" art).
    var alt = false
    /// Movie: the poof has played and the character is hidden.
    var gone = false
    /// Changes every time a state is (re)entered, so entry animations replay.
    var serial = 0
    /// Stills only (Reduce motion, Low Power Mode).
    var stills = false
    /// Running Claude Code subagents (shadow clones).
    var clones = 0
}

// MARK: - Settings

struct CharacterPrefs: Codable, Equatable {
    var enabled = false
    /// "" until a pack has been chosen once (then a personal pack, if one is installed, is picked).
    var packID = ""
    var reduceMotion = false
    var touchBar = true
    var clones = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CharacterPrefs()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        enabled = v(.enabled, d.enabled)
        packID = v(.packID, d.packID)
        reduceMotion = v(.reduceMotion, d.reduceMotion)
        touchBar = v(.touchBar, d.touchBar)
        clones = v(.clones, d.clones)
    }
}

// MARK: - Packs

/// One piece of art for a state. Sizes are points in the 124 x 120 character box.
struct CharacterMedia {
    enum Source: Equatable { case file(URL), drawn(String) }
    var still: Source?
    var stillHeight: CGFloat = 104
    var stillBottom: CGFloat = 0
    var video: URL?
    var videoHeight: CGFloat = 116
    var videoBottom: CGFloat = 0
    /// The video was made on black (no alpha): it is shown on black with soft edges, and only
    /// on a dark island.
    var videoOnBlack = true
}

final class CharacterPack: Identifiable {
    let id: String
    let name: String
    let summary: String
    let credit: String
    let folder: URL?
    /// Keys: CharacterState raw values plus "idleAlt".
    let media: [String: CharacterMedia]
    /// Small chest-up stills for the Touch Bar (optional; falls back to `media`).
    let compact: [String: CharacterMedia.Source]
    private var cache: [String: CGImage] = [:]

    init(id: String, name: String, summary: String, credit: String, folder: URL?,
         media: [String: CharacterMedia], compact: [String: CharacterMedia.Source]) {
        self.id = id; self.name = name; self.summary = summary; self.credit = credit
        self.folder = folder; self.media = media; self.compact = compact
    }

    var isBuiltIn: Bool { folder == nil }

    /// Art for a state, with sensible fallbacks (shelf -> finished, meeting -> idle, ...).
    func media(for state: CharacterState, alt: Bool) -> CharacterMedia? {
        if state == .idle && alt, let m = media["idleAlt"] { return m }
        if let m = media[state.rawValue] { return m }
        switch state {
        case .shelf: return media["finished"] ?? media["idle"]
        case .meeting, .sleeping, .finished, .approval, .thinking, .music: return media["idle"]
        default: return nil
        }
    }

    func compactSource(for state: CharacterState, alt: Bool) -> CharacterMedia.Source? {
        if state == .idle && alt, let s = compact["idleAlt"] { return s }
        if let s = compact[state.rawValue] { return s }
        if state == .shelf { return compact["finished"] }
        if state == .meeting { return compact["idle"] }
        return nil
    }

    @MainActor func image(_ source: CharacterMedia.Source) -> CGImage? {
        let key: String
        switch source {
        case .file(let u): key = u.path
        case .drawn(let k): key = "drawn:" + k
        }
        if let c = cache[key] { return c }
        var img: CGImage?
        switch source {
        case .file(let u):
            if let ns = NSImage(contentsOf: u) { img = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        case .drawn(let k):
            img = MochiArt.image(k)
        }
        if let img { cache[key] = img }
        return img
    }

    /// Small avatar for pickers (the idle still).
    @MainActor var avatar: CGImage? {
        guard let s = media["idle"]?.still else { return nil }
        return image(s)
    }
}

/// Reads manifest.json packs. A manifest looks like:
///
///     { "name": "My Pet", "description": "...", "credit": "...",
///       "states": { "idle": { "still": "art/idle.png", "height": 112 },
///                   "idleAlt": { "still": "art/snack.png", "height": 104 },
///                   "music": { "still": "art/run.png", "height": 76, "bottom": 16,
///                              "video": "video/run.mp4", "videoHeight": 116, "videoOnBlack": true }, ... },
///       "touchBar": { "idle": "art/small-idle.png", ... } }
///
/// Every path must stay inside the pack folder. Unknown keys are ignored.
enum CharacterManifest {
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]
    static let videoTypes: Set<String> = ["mp4", "mov", "m4v"]
    static let keys: Set<String> = Set(CharacterState.allCases.map(\.rawValue)).union(["idleAlt"])

    static func load(folder: URL) -> CharacterPack? {
        let url = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url), data.count < 256 * 1024 else { return nil }
        return parse(data, folder: folder)
    }

    static func parse(_ data: Data, folder: URL) -> CharacterPack? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let states = obj["states"] as? [String: Any] else { return nil }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        func file(_ any: Any?, _ types: Set<String>) -> URL? {
            guard let rel = any as? String, !rel.isEmpty, !rel.hasPrefix("/") else { return nil }
            let u = root.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
            guard u.path.hasPrefix(root.path + "/"), types.contains(u.pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: u.path) else { return nil }
            return u
        }
        func num(_ any: Any?, _ def: CGFloat) -> CGFloat {
            guard let n = any as? NSNumber else { return def }
            return CGFloat(min(max(n.doubleValue, 0), 240))
        }
        var media: [String: CharacterMedia] = [:]
        for (k, v) in states where keys.contains(k) {
            guard let d = v as? [String: Any] else { continue }
            var m = CharacterMedia()
            m.still = file(d["still"], imageTypes).map { .file($0) }
            m.stillHeight = num(d["height"], 104)
            m.stillBottom = num(d["bottom"], 0)
            m.video = file(d["video"], videoTypes)
            m.videoHeight = num(d["videoHeight"], m.stillHeight)
            m.videoBottom = num(d["videoBottom"], 0)
            m.videoOnBlack = (d["videoOnBlack"] as? Bool) ?? true
            if m.still != nil || m.video != nil { media[k] = m }
        }
        guard media["idle"] != nil else { return nil }   // idle is the one state every pack needs
        var compact: [String: CharacterMedia.Source] = [:]
        for (k, v) in (obj["touchBar"] as? [String: Any]) ?? [:] where keys.contains(k) {
            if let u = file(v, imageTypes) { compact[k] = .file(u) }
        }
        let name = (obj["name"] as? String).map { String($0.prefix(40)) } ?? folder.lastPathComponent
        return CharacterPack(id: "pack:" + folder.lastPathComponent, name: name,
                             summary: String((obj["description"] as? String ?? "").prefix(200)),
                             credit: String((obj["credit"] as? String ?? "").prefix(200)),
                             folder: folder, media: media, compact: compact)
    }
}

@Observable @MainActor
final class CharacterLibrary {
    static let shared = CharacterLibrary()
    private(set) var packs: [CharacterPack] = []

    static var folder: URL { Env.supportDir.appendingPathComponent("Characters", isDirectory: true) }

    private init() { reload() }

    func reload() {
        var list: [CharacterPack] = [MochiArt.pack]
        let fm = FileManager.default
        if let dirs = try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for d in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let p = CharacterManifest.load(folder: d) { list.append(p) }
            }
        }
        packs = list
    }

    func pack(_ id: String) -> CharacterPack? { packs.first { $0.id == id } }

    func openFolder() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(Self.folder)
    }
}

// MARK: - Engine (real signals -> state)

@Observable @MainActor
final class CharacterEngine {
    static let shared = CharacterEngine()

    private(set) var frame = CharacterFrame()
    /// Settings preview: a state shown on the real island for a short while.
    private(set) var override: CharacterState?
    @ObservationIgnored private var overrideUntil = Date.distantPast

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var sessions: [String: Date] = [:]
    @ObservationIgnored private var agents: [String: Date] = [:]
    @ObservationIgnored private var finishedUntil = Date.distantPast
    @ObservationIgnored private var shelfUntil = Date.distantPast
    @ObservationIgnored private var goneTask: Task<Void, Never>?
    @ObservationIgnored private var idleTicks = 0
    @ObservationIgnored private var fullscreenCache: (at: Date, value: Bool) = (.distantPast, false)
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Screens asleep: rigs pause their videos and animations.
    private(set) var screensAsleep = false
    /// Last thing shown on the Shelf (for the Touch Bar line).
    private(set) var lastShelfName = ""

    var prefs: CharacterPrefs { AppSettings.shared.prefs.character }
    var pack: CharacterPack? { prefs.enabled ? CharacterLibrary.shared.pack(prefs.packID) : nil }
    /// The character is on and has art.
    var active: Bool { pack != nil }
    /// Visible right now (on, and not hidden by a movie).
    var showing: Bool { active && !frame.gone }

    var stills: Bool { prefs.reduceMotion || Look.shared.reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled }

    func start() {
        pickDefaultPack()
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { CharacterEngine.shared.tick() } }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CharacterEngine.shared.screensAsleep = true }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CharacterEngine.shared.screensAsleep = false; CharacterEngine.shared.tick() }
        })
        tick()
    }

    /// First run: a personal pack wins if one is installed (it was put there on purpose); the
    /// built-in Mochi stays off until switched on.
    private func pickDefaultPack() {
        guard AppSettings.shared.prefs.character.packID.isEmpty else { return }
        var p = AppSettings.shared.prefs
        if let personal = CharacterLibrary.shared.packs.first(where: { !$0.isBuiltIn }) {
            p.character.packID = personal.id
            p.character.enabled = true
        } else {
            p.character.packID = MochiArt.pack.id
        }
        AppSettings.shared.prefs = p
    }

    // MARK: Events from Glance

    func claude(event: String, session: String, msg: [String: Any]) {
        let key = session.isEmpty ? "-" : session
        let now = Date()
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PreCompact":
            sessions[key] = now
        case "Stop":
            sessions[key] = nil
            agents = agents.filter { !$0.key.hasPrefix(key + "/") }
            finishedUntil = now.addingTimeInterval(3.2)
        case "StopFailure", "SessionEnd":
            sessions[key] = nil
            agents = agents.filter { !$0.key.hasPrefix(key + "/") }
        case "Notification":
            // Waiting for the user's next prompt: no longer thinking.
            if msg["notification_type"] as? String == "idle_prompt" { sessions[key] = nil }
        case "SubagentStart":
            sessions[key] = now
            let agent = msg["agent_id"] as? String ?? UUID().uuidString
            agents[key + "/" + agent] = now
        case "SubagentStop":
            let agent = msg["agent_id"] as? String
            if let agent { agents[key + "/" + agent] = nil }
            else if let k = agents.filter({ $0.key.hasPrefix(key + "/") }).min(by: { $0.value < $1.value })?.key { agents[k] = nil }
        default:
            return
        }
        tick()
    }

    func shelfDropped(name: String) {
        lastShelfName = name
        shelfUntil = Date().addingTimeInterval(2.2)
        tick()
    }

    /// Settings preview: play a state on the real island for `seconds` (nil ends it).
    func preview(_ s: CharacterState?, seconds: TimeInterval = 12) {
        override = s
        overrideUntil = s == nil ? .distantPast : Date().addingTimeInterval(seconds)
        if s == .finished { finishedUntil = .distantPast }
        tick(force: s != nil)
    }

    // MARK: State

    func signals(now: Date = Date()) -> CharacterSignals {
        // Sessions that went quiet for 10 minutes are over (a crashed Claude Code must not keep him busy).
        sessions = sessions.filter { now.timeIntervalSince($0.value) < 600 }
        agents = agents.filter { now.timeIntervalSince($0.value) < 1800 }
        let model = IslandModel.shared
        // The Done celebration plays in the pill first; the thumbs-up follows it.
        if finishedUntil > now, model.celebration != nil { finishedUntil = max(finishedUntil, now.addingTimeInterval(2.5)) }
        var s = CharacterSignals()
        s.approval = !model.permissions.isEmpty
        s.finished = finishedUntil > now
        s.thinking = !sessions.isEmpty
        s.movie = movieNow(now)
        s.shelf = shelfUntil > now
        if let start = CalendarService.shared.nextStart {
            let left = start.timeIntervalSince(now)
            s.meeting = left > 0 && left <= 300
        }
        let np = NowPlaying.shared
        s.music = np.isPlaying && np.bundleID != Bundle.main.bundleIdentifier && !s.movie
        s.sleeping = Self.secondsSinceInput() > 600
        return s
    }

    static let videoApps: Set<String> = ["com.apple.QuickTimePlayerX", "com.apple.TV", "org.videolan.vlc", "com.colliderli.iina",
                                         "io.mpv", "com.netflix.Netflix", "com.firecore.infuse", "com.apple.Photos"]
    static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
                                        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"]

    private func movieNow(_ now: Date) -> Bool {
        let cinema = ChromeAmbilight.shared
        if AppSettings.shared.prefs.cinemaExtension && cinema.connected && cinema.playing { return true }
        let np = NowPlaying.shared
        guard np.isPlaying else { return false }
        if Self.videoApps.contains(np.bundleID) { return true }
        // A browser playing something with a full-screen window in front: a video (YouTube etc.).
        if Self.browsers.contains(np.bundleID) {
            if now.timeIntervalSince(fullscreenCache.at) > 2 { fullscreenCache = (now, Self.frontAppIsFullScreen(np.bundleID)) }
            return fullscreenCache.value
        }
        return false
    }

    /// The front app is `bundleID` and one of its windows covers a whole screen. Window bounds
    /// need no permission (titles would, and are not read).
    static func frontAppIsFullScreen(_ bundleID: String) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundleID else { return false }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let screens = NSScreen.screens.map(\.frame.size)
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = b["Width"], let height = b["Height"] else { continue }
            if screens.contains(where: { abs($0.width - width) < 2 && abs($0.height - height) < 2 }) { return true }
        }
        return false
    }

    static func secondsSinceInput() -> Double {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    func tick(force: Bool = false) {
        guard active else {
            if frame.state != .idle || frame.gone { frame = CharacterFrame() }
            CharacterTouchBar.shared.update()
            return
        }
        let now = Date()
        if override != nil && overrideUntil <= now { override = nil }
        let real = signals(now: now).resolved
        let next = override ?? real
        var f = frame
        f.stills = stills
        f.clones = prefs.clones ? min(agents.count, 99) : 0
        if next != f.state || force {
            f.state = next
            f.serial &+= 1
            f.gone = false
            f.alt = false
            idleTicks = 0
            goneTask?.cancel()
            if next == .movie {
                let delay = f.stills ? 0.05 : 1.45
                goneTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, let self, self.frame.state == .movie else { return }
                    withAnimation(IslandModel.closeSpring) { self.frame.gone = true }
                    CharacterTouchBar.shared.update()
                }
            }
        } else if next == .idle {
            // A snack moment for about 3 of every 8 seconds.
            idleTicks += 1
            f.alt = idleTicks % 8 >= 5
        }
        if f != frame {
            withAnimation(IslandModel.openSpring) { frame = f }
            CharacterTouchBar.shared.update()
        }
    }
}

// MARK: - Self test (`Glance --character-selftest`: prints results and exits, shows nothing)

@MainActor
enum CharacterSelfTest {
    static func run() -> Never {
        var lines: [String] = [], failures = 0
        func check(_ name: String, _ ok: Bool) { lines.append((ok ? "PASS " : "FAIL ") + name); if !ok { failures += 1 } }
        var s = CharacterSignals()
        check("nothing -> idle", s.resolved == .idle)
        s.sleeping = true; check("sleeping", s.resolved == .sleeping)
        s.music = true; check("music beats sleeping", s.resolved == .music)
        s.meeting = true; check("meeting beats music", s.resolved == .meeting)
        s.shelf = true; check("shelf beats meeting", s.resolved == .shelf)
        s.movie = true; check("movie beats shelf", s.resolved == .movie)
        s.thinking = true; check("thinking beats movie", s.resolved == .thinking)
        s.finished = true; check("finished beats thinking", s.resolved == .finished)
        s.approval = true; check("approval beats everything", s.resolved == .approval)
        check("priority covers every state", Set(CharacterState.priority) == Set(CharacterState.allCases))
        // Manifest parsing: path escapes and missing files are refused, idle is required.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("glance-pack-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp.appendingPathComponent("art"), withIntermediateDirectories: true)
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:])
        try? png?.write(to: tmp.appendingPathComponent("art/a.png"))
        let good = #"{"name":"T","states":{"idle":{"still":"art/a.png","height":100},"music":{"still":"../../etc/passwd"},"sleeping":{"still":"art/missing.png"}}}"#
        let p = CharacterManifest.parse(Data(good.utf8), folder: tmp)
        check("manifest loads", p != nil)
        check("idle art kept", p?.media["idle"]?.still != nil)
        check("path outside the pack refused", p?.media["music"] == nil)
        check("missing file refused", p?.media["sleeping"] == nil)
        check("meeting falls back to idle art", p?.media(for: .meeting, alt: false)?.still == p?.media["idle"]?.still)
        check("no idle -> no pack", CharacterManifest.parse(Data(#"{"states":{"music":{"still":"art/a.png"}}}"#.utf8), folder: tmp) == nil)
        check("drawn Mochi renders", MochiArt.pack.media.values.allSatisfy { m in m.still.flatMap { MochiArt.pack.image($0) } != nil })
        try? FileManager.default.removeItem(at: tmp)
        // Installed packs.
        for pk in CharacterLibrary.shared.packs {
            let states = CharacterState.allCases.filter { pk.media(for: $0, alt: false) != nil }.map(\.rawValue)
            let videos = pk.media.values.compactMap(\.video).count
            lines.append("pack \(pk.id) '\(pk.name)': \(states.count) states with art, \(videos) videos, \(pk.compact.count) Touch Bar stills")
        }
        if let out = ProcessInfo.processInfo.environment["GLANCE_SELFTEST_OUT"] {
            for pk in CharacterLibrary.shared.packs {
                for st in CharacterState.allCases {
                    guard let img = CharacterRigView.snapshot(st, pack: pk) else { continue }
                    let url = URL(fileURLWithPath: out).appendingPathComponent("\(pk.id.replacingOccurrences(of: ":", with: "-"))-\(st.rawValue).png")
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
        lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        print(lines.joined(separator: "\n"))
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
