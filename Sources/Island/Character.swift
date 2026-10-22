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
    /// The shadow clones themselves (running, waiting for you, or done and about to go).
    var helpers: [CharacterClone] = []
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

/// How a pack's shadow clones arrive and leave: a puff of smoke (the default), fox-fire, or a
/// dusting of rice flour.
enum CloneEffect: String, CaseIterable {
    case smoke, foxfire, flour
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
    /// Entrance and exit of this pack's shadow clones.
    let cloneEffect: CloneEffect
    private var cache: [String: CGImage] = [:]

    init(id: String, name: String, summary: String, credit: String, folder: URL?,
         media: [String: CharacterMedia], compact: [String: CharacterMedia.Source], cloneEffect: CloneEffect = .smoke) {
        self.id = id; self.name = name; self.summary = summary; self.credit = credit
        self.folder = folder; self.media = media; self.compact = compact; self.cloneEffect = cloneEffect
    }

    /// Ships with Glance (Mochi drawn in code, Kitsune and Pocket ninja in the app's Resources).
    var isBuiltIn: Bool { id.hasPrefix("builtin:") }

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
///       "touchBar": { "idle": "art/small-idle.png", ... },
///       "clones": { "effect": "smoke" } }
///
/// "clones" is optional: how the pack's shadow clones (one per running Claude Code subagent)
/// appear and leave. "effect" is "smoke" (the default), "foxfire" or "flour".
///
/// Every path must stay inside the pack folder. Unknown keys are ignored.
enum CharacterManifest {
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]
    static let videoTypes: Set<String> = ["mp4", "mov", "m4v"]
    static let keys: Set<String> = Set(CharacterState.allCases.map(\.rawValue)).union(["idleAlt"])

    /// `builtIn`: a pack bundled in the app (id "builtin:<folder>"); otherwise a personal pack.
    static func load(folder: URL, builtIn: Bool = false) -> CharacterPack? {
        let url = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url), data.count < 256 * 1024 else { return nil }
        return parse(data, folder: folder, builtIn: builtIn)
    }

    static func parse(_ data: Data, folder: URL, builtIn: Bool = false) -> CharacterPack? {
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
        return CharacterPack(id: (builtIn ? "builtin:" : "pack:") + folder.lastPathComponent, name: name,
                             summary: String((obj["description"] as? String ?? "").prefix(200)),
                             credit: String((obj["credit"] as? String ?? "").prefix(200)),
                             folder: folder, media: media, compact: compact,
                             cloneEffect: ((obj["clones"] as? [String: Any])?["effect"] as? String).flatMap(CloneEffect.init(rawValue:)) ?? .smoke)
    }
}

@Observable @MainActor
final class CharacterLibrary {
    static let shared = CharacterLibrary()
    private(set) var packs: [CharacterPack] = []

    /// Folders in Contents/Resources/Characters, in picker order.
    static let bundled = ["kitsune", "pocket-ninja"]

    static var folder: URL { Env.supportDir.appendingPathComponent("Characters", isDirectory: true) }

    private init() { reload() }

    func reload() {
        var list: [CharacterPack] = [MochiArt.pack]
        let fm = FileManager.default
        // Built-in packs bundled in the app, in picker order.
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Characters", isDirectory: true) {
            for name in Self.bundled {
                if let p = CharacterManifest.load(folder: res.appendingPathComponent(name, isDirectory: true), builtIn: true) { list.append(p) }
            }
        }
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

    private(set) var frame = CharacterFrame() { didSet { if hidden != frame.gone { hidden = frame.gone } } }
    /// `frame.gone`, kept apart so views that only ask `showing` (the whole island) are not
    /// invalidated by every pose change; the rig and the indicator follow `frame` themselves.
    private(set) var hidden = false
    /// Settings preview: a state shown on the real island for a short while.
    private(set) var override: CharacterState?
    @ObservationIgnored private var overrideUntil = Date.distantPast

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var sessions: [String: Date] = [:]
    @ObservationIgnored private var clones = CloneTracker()
    @ObservationIgnored private var finishedUntil = Date.distantPast
    @ObservationIgnored private var shelfUntil = Date.distantPast
    @ObservationIgnored private var goneTask: Task<Void, Never>?
    @ObservationIgnored private var idleTicks = 0
    @ObservationIgnored private var wasOff = false
    @ObservationIgnored private var fullscreenCache: (at: Date, value: Bool) = (.distantPast, false)
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Screens asleep: rigs pause their videos and animations.
    private(set) var screensAsleep = false
    /// Shadow clones take over Home's cards area. Goes false a moment after the last clone
    /// leaves, so its poof can play before the cards come back. Kept apart from `frame` so the
    /// island only re-lays out when this flips.
    private(set) var clonesShowing = false
    @ObservationIgnored private var cloneCellsTask: Task<Void, Never>?
    /// Last thing shown on the Shelf (for the Touch Bar line).
    private(set) var lastShelfName = ""

    var prefs: CharacterPrefs { AppSettings.shared.prefs.character }
    var pack: CharacterPack? { prefs.enabled ? CharacterLibrary.shared.pack(prefs.packID) : nil }
    /// The character is on and has art.
    var active: Bool { pack != nil }
    /// Visible right now (on, and not hidden by a movie).
    var showing: Bool { active && !hidden }

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
        let clonesBefore = clones.count
        clones.handle(event: event, session: key, msg: msg, now: now)
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PreCompact":
            sessions[key] = now
        case "Stop":
            // A Stop that carries agent_id is a subagent finishing, not the turn.
            guard (msg["agent_id"] as? String ?? "").isEmpty else { break }
            sessions[key] = nil
            finishedUntil = now.addingTimeInterval(3.2)
        case "StopFailure", "SessionEnd":
            sessions[key] = nil
        case "Notification":
            // Waiting for the user's next prompt: no longer thinking.
            if msg["notification_type"] as? String == "idle_prompt" { sessions[key] = nil }
        case "SubagentStart":
            sessions[key] = now
        case "SubagentStop":
            break
        default:
            if clones.count == clonesBefore { return }
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
        clones.expire(now: now)
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

    /// Clones ("session/agent_id") whose subagent is waiting on a permission request.
    private func askingClones() -> Set<String> {
        Set(IslandModel.shared.permissions.compactMap { p in p.agentID.isEmpty ? nil : (p.session.isEmpty ? "-" : p.session) + "/" + p.agentID })
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
            // Off: nothing changes from second to second, so only a switch-off does any work.
            let reset = frame.state != .idle || frame.gone
            if reset || !wasOff || CharacterTouchBar.shared.previewing {
                if reset { frame = CharacterFrame() }
                wasOff = true
                CharacterTouchBar.shared.update()
            }
            return
        }
        wasOff = false
        let now = Date()
        if override != nil && overrideUntil <= now { override = nil }
        let real = signals(now: now).resolved
        let next = override ?? real
        var f = frame
        f.stills = stills
        f.clones = prefs.clones ? min(clones.count, 99) : 0
        f.helpers = prefs.clones ? clones.clones(asking: askingClones()) : []
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
        updateCloneCells()
    }

    private func updateCloneCells() {
        let want = !frame.gone && !frame.helpers.isEmpty
        if want {
            cloneCellsTask?.cancel(); cloneCellsTask = nil
            if !clonesShowing { withAnimation(IslandModel.openSpring) { clonesShowing = true } }
        } else if clonesShowing && cloneCellsTask == nil {
            cloneCellsTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.1))
                guard !Task.isCancelled, let self else { return }
                self.cloneCellsTask = nil
                if self.frame.gone || self.frame.helpers.isEmpty { withAnimation(.easeInOut(duration: 0.45)) { self.clonesShowing = false } }
            }
        }
    }

}

// MARK: - Shadow clones

/// Running Claude Code subagents, one entry per agent per session (the shadow clones). Fed by the
/// hook events (https://code.claude.com/docs/en/hooks): SubagentStart and SubagentStop carry
/// `agent_id` and `agent_type`; tool events from inside a subagent carry them too and count as a
/// sign of life. A clone that finished stays for a moment as "done" before it goes.
struct CloneTracker {
    struct Agent: Equatable {
        var session: String
        var id: String
        /// agent_type ("Explore", "general-purpose", "my-plugin:reviewer", ...), may be empty.
        var type: String
        var started: Date
        var seen: Date
        /// Order of arrival (stable tint and position).
        var ordinal: Int
    }
    /// No word from an agent for this long: its SubagentStop was missed (Claude Code quit, hook
    /// timed out), so the clone goes. Long Read/Grep runs send no hooked events, hence the margin.
    static let quietExpiry: TimeInterval = 20 * 60
    /// A finished clone shows "done" (a hop) this long before it poofs.
    static let doneHold: TimeInterval = 1.3
    private(set) var agents: [String: Agent] = [:]
    /// Finished clones still showing "done", until the given time.
    private(set) var leaving: [String: (agent: Agent, until: Date)] = [:]
    private var arrivals = 0
    var count: Int { agents.count }

    mutating func handle(event: String, session: String, msg: [String: Any], now: Date) {
        let id = (msg["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let type = msg["agent_type"] as? String ?? ""
        switch event {
        case "SubagentStart":
            // Also fires when a subagent is resumed: same id, same clone.
            let aid = id ?? UUID().uuidString
            let key = session + "/" + aid
            if let a = agents[key] {
                agents[key]?.seen = now
                if a.type.isEmpty { agents[key]?.type = type }
            } else {
                let back = leaving.removeValue(forKey: key)?.agent
                arrivals += 1
                agents[key] = Agent(session: session, id: aid, type: type.isEmpty ? back?.type ?? "" : type,
                                    started: back?.started ?? now, seen: now, ordinal: back?.ordinal ?? arrivals)
            }
        case "SubagentStop":
            // Claude Code's own internal agents (prompt suggestions, /btw) stop without a start:
            // an unknown id is ignored. Without any id, the oldest clone of the session goes.
            if let id { finish(session + "/" + id, now: now) }
            else if let k = agents.filter({ $0.value.session == session }).min(by: { $0.value.started < $1.value.started })?.key { finish(k, now: now) }
        case "Stop":
            if let id { finish(session + "/" + id, now: now); return }
            // The main turn ended. Background subagents may still run (listed in background_tasks):
            // keep that many of the most recently active clones, the rest are done.
            let running = (msg["background_tasks"] as? [[String: Any]] ?? []).filter {
                $0["type"] as? String == "subagent" && !["completed", "failed", "killed", "stopped", "done"].contains($0["status"] as? String ?? "")
            }.count
            let mine = agents.filter { $0.value.session == session }.sorted { $0.value.seen > $1.value.seen }
            for (k, _) in mine.dropFirst(running) { finish(k, now: now) }
        case "StopFailure", "SessionEnd":
            // Gone without a celebration.
            agents = agents.filter { $0.value.session != session }
            leaving = leaving.filter { $0.value.agent.session != session }
        case "Notification":
            // idle_prompt only fires once no background agent is still running.
            if msg["notification_type"] as? String == "idle_prompt" {
                for k in agents.keys where agents[k]?.session == session { finish(k, now: now) }
            }
        default:
            if let id, agents[session + "/" + id] != nil {
                agents[session + "/" + id]?.seen = now
                if !type.isEmpty, agents[session + "/" + id]?.type.isEmpty == true { agents[session + "/" + id]?.type = type }
            }
        }
    }

    private mutating func finish(_ key: String, now: Date) {
        guard let a = agents.removeValue(forKey: key) else { return }
        leaving[key] = (a, now.addingTimeInterval(Self.doneHold))
    }

    mutating func expire(now: Date) {
        agents = agents.filter { now.timeIntervalSince($0.value.seen) < Self.quietExpiry }
        leaving = leaving.filter { $0.value.until > now }
    }

    /// The clones to draw, oldest first. `asking`: keys ("session/agent_id") with a pending
    /// permission request.
    func clones(asking: Set<String>) -> [CharacterClone] {
        let live = agents.map { k, a in CharacterClone(key: k, label: Self.label(a.type), phase: asking.contains(k) ? .needsYou : .working, ordinal: a.ordinal) }
        let done = leaving.map { k, l in CharacterClone(key: k, label: Self.label(l.agent.type), phase: .done, ordinal: l.agent.ordinal) }
        return (live + done).sorted { $0.ordinal < $1.ordinal }
    }

    /// A short label from agent_type: "my-plugin:code-reviewer" -> "Code reviewer",
    /// "general-purpose" or nothing -> "Helper".
    static func label(_ type: String) -> String {
        var t = type.split(separator: ":").last.map(String.init) ?? ""
        t = t.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.lowercased() == "general purpose" { return "Helper" }
        if t.count > 14 { t = String(t.prefix(13)).trimmingCharacters(in: .whitespaces) + "\u{2026}" }
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}

/// One shadow clone as the rigs draw it.
struct CharacterClone: Equatable, Identifiable {
    enum Phase: String { case working, needsYou, done }
    var key: String
    var label: String
    var phase: Phase
    var ordinal: Int
    var id: String { key }
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
        // Shadow clones: hook event sequences as Claude Code sends them.
        var ct = CloneTracker(); let t0 = Date()
        for i in 1...3 { ct.handle(event: "SubagentStart", session: "s1", msg: ["agent_id": "a\(i)", "agent_type": "Explore"], now: t0) }
        check("clones: one per running subagent", ct.count == 3)
        ct.handle(event: "SubagentStart", session: "s1", msg: ["agent_id": "a1"], now: t0)
        check("clones: a resumed subagent is not a new clone", ct.count == 3)
        ct.handle(event: "SubagentStart", session: "s2", msg: ["agent_id": "a1"], now: t0)
        check("clones: same agent id in another session counts", ct.count == 4)
        ct.handle(event: "SubagentStop", session: "s1", msg: ["agent_id": "zz", "agent_type": ""], now: t0)
        check("clones: stop of an unknown (internal) agent ignored", ct.count == 4)
        ct.handle(event: "SubagentStop", session: "s1", msg: ["agent_id": "a2"], now: t0)
        check("clones: SubagentStop clears its clone", ct.count == 3 && ct.agents["s1/a2"] == nil)
        ct.handle(event: "PostToolUse", session: "s1", msg: ["agent_id": "a3", "tool_name": "Bash"], now: t0.addingTimeInterval(1000))
        ct.expire(now: t0.addingTimeInterval(CloneTracker.quietExpiry + 1))
        check("clones: quiet agents expire, active ones stay", ct.count == 1 && ct.agents["s1/a3"] != nil)
        ct = CloneTracker()
        for i in 1...3 { ct.handle(event: "SubagentStart", session: "s1", msg: ["agent_id": "b\(i)"], now: t0.addingTimeInterval(Double(i))) }
        ct.handle(event: "Stop", session: "s1", msg: ["background_tasks": [["type": "subagent", "status": "running"], ["type": "shell", "status": "running"]]], now: t0)
        check("clones: Stop keeps background subagents still running", ct.count == 1 && ct.agents["s1/b3"] != nil)
        ct.handle(event: "Stop", session: "s1", msg: ["background_tasks": []], now: t0)
        check("clones: main Stop clears the rest", ct.count == 0)
        ct.handle(event: "SubagentStart", session: "s1", msg: ["agent_id": "c1"], now: t0)
        ct.handle(event: "Stop", session: "s1", msg: ["agent_id": "c1"], now: t0)
        check("clones: a Stop with agent_id clears only that clone", ct.count == 0)
        ct.handle(event: "SubagentStart", session: "s1", msg: ["agent_id": "d1"], now: t0)
        ct.handle(event: "SubagentStart", session: "s2", msg: ["agent_id": "d2"], now: t0)
        ct.handle(event: "SessionEnd", session: "s1", msg: [:], now: t0)
        check("clones: SessionEnd clears only that session", ct.count == 1 && ct.agents["s2/d2"] != nil)
        ct.handle(event: "Notification", session: "s2", msg: ["notification_type": "idle_prompt"], now: t0)
        check("clones: idle prompt clears the session", ct.count == 0)
        // Per-clone labels and phases.
        ct = CloneTracker()
        ct.handle(event: "SubagentStart", session: "s1", msg: ["agent_id": "e1", "agent_type": "Explore"], now: t0)
        ct.handle(event: "SubagentStart", session: "s1", msg: ["agent_id": "e2", "agent_type": "my-plugin:code-reviewer"], now: t0)
        ct.handle(event: "SubagentStart", session: "s1", msg: ["agent_id": "e3", "agent_type": "general-purpose"], now: t0)
        var cl = ct.clones(asking: ["s1/e2"])
        check("clones: labelled from agent_type, oldest first", cl.map(\.label) == ["Explore", "Code reviewer", "Helper"])
        check("clones: the agent with a pending permission waves", cl.map(\.phase) == [.working, .needsYou, .working])
        check("clones: no type -> Helper, long types shortened", CloneTracker.label("") == "Helper" && CloneTracker.label("a-very-long-agent-name").count <= 14)
        ct.handle(event: "SubagentStop", session: "s1", msg: ["agent_id": "e1", "agent_type": "Explore"], now: t0)
        cl = ct.clones(asking: [])
        check("clones: a finished clone shows done before it goes", ct.count == 2 && cl.first?.phase == .done && cl.first?.label == "Explore")
        ct.expire(now: t0.addingTimeInterval(CloneTracker.doneHold + 0.1))
        check("clones: then it leaves", ct.clones(asking: []).count == 2)
        ct.handle(event: "SubagentStop", session: "s1", msg: ["agent_id": "e2"], now: t0)
        ct.handle(event: "SubagentStart", session: "s1", msg: ["agent_id": "e2"], now: t0)
        cl = ct.clones(asking: [])
        check("clones: resumed while done keeps its place and type", cl.map(\.label) == ["Code reviewer", "Helper"] && cl.allSatisfy { $0.phase == .working })
        ct.handle(event: "Stop", session: "s1", msg: ["background_tasks": []], now: t0)
        check("clones: main Stop sends the rest off as done", ct.count == 0 && ct.clones(asking: []).allSatisfy { $0.phase == .done })
        ct.handle(event: "SessionEnd", session: "s1", msg: [:], now: t0)
        check("clones: SessionEnd clears done clones too", ct.clones(asking: []).isEmpty)
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
        check("clone effect defaults to smoke", p?.cloneEffect == .smoke)
        let fx = #"{"states":{"idle":{"still":"art/a.png"}},"clones":{"effect":"foxfire"}}"#
        check("clone effect from the manifest", CharacterManifest.parse(Data(fx.utf8), folder: tmp)?.cloneEffect == .foxfire)
        let bad = #"{"states":{"idle":{"still":"art/a.png"}},"clones":{"effect":"lasers"}}"#
        check("unknown clone effect -> smoke", CharacterManifest.parse(Data(bad.utf8), folder: tmp)?.cloneEffect == .smoke)
        check("built-in clone effects", MochiArt.pack.cloneEffect == .flour
              && CharacterLibrary.shared.pack("builtin:kitsune").map { $0.cloneEffect == .foxfire } != false
              && CharacterLibrary.shared.pack("builtin:pocket-ninja").map { $0.cloneEffect == .smoke } != false)
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
