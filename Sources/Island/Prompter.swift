import AppKit
import SwiftUI
import Observation

// MARK: feat/prompter
//
// Teleprompter: a box that drops down directly under the pill (as close to the camera as the
// screen allows). Text is a stack of static layers that Core Animation moves in the render
// server, so steady scrolling costs the app nothing. The window is excluded from screen
// sharing and recordings. Voice follow is in PrompterVoice.swift, matching in PrompterMatcher.swift.

// MARK: - Script library (local only: ~/Library/Application Support/Glance/prompter.json, 0600)

struct PrompterScript: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var text: String
    var date = Date()
    var preview: String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.isEmpty ? "Empty script" : String(flat.prefix(90))
    }
}

@Observable @MainActor
final class PrompterLibrary {
    static let shared = PrompterLibrary()
    private(set) var scripts: [PrompterScript] = []
    /// Ask the Prompter page to open this script in the editor (debug / future ⌘K "Edit script").
    var editRequest: UUID?
    /// Isolated test instances keep their scripts next to their private socket, never in the real folder.
    private var file: URL {
        if let s = Env.testSocket { return URL(fileURLWithPath: s).deletingLastPathComponent().appendingPathComponent("prompter.json") }
        return ClaudeServer.directory.appendingPathComponent("prompter.json")
    }

    private init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([PrompterScript].self, from: d) { scripts = s }
    }

    @discardableResult
    func add(title: String = "", text: String = "") -> PrompterScript {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = PrompterScript(title: t.isEmpty ? "Untitled script" : t, text: text)
        scripts.insert(s, at: 0); save(); return s
    }
    func update(_ s: PrompterScript) {
        guard let i = scripts.firstIndex(where: { $0.id == s.id }) else { return }
        guard scripts[i].title != s.title || scripts[i].text != s.text else { return }
        var n = s; n.date = Date()
        if n.title.trimmingCharacters(in: .whitespaces).isEmpty { n.title = "Untitled script" }
        scripts[i] = n; save()
    }
    func rename(_ s: PrompterScript, to title: String) { var n = s; n.title = title; update(n) }
    func delete(_ s: PrompterScript) { scripts.removeAll { $0.id == s.id }; save() }

    /// A new script from the clipboard text. Returns nil when the clipboard has no text.
    @discardableResult
    func pasteNew(from pb: NSPasteboard = .general) -> PrompterScript? {
        guard let t = pb.string(forType: .string), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let first = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Pasted script"
        return add(title: String(first.prefix(60)), text: t)
    }

    func importFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.plainText, .init(filenameExtension: "md") ?? .plainText, .init(filenameExtension: "markdown") ?? .plainText]
        p.allowsMultipleSelection = true
        p.message = "Choose .txt or .md scripts"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        for u in p.urls { importURL(u) }
    }

    @discardableResult
    func importURL(_ u: URL) -> PrompterScript? {
        guard let raw = (try? String(contentsOf: u, encoding: .utf8)) ?? (try? String(contentsOf: u, encoding: .isoLatin1)) else { return nil }
        let isMD = ["md", "markdown"].contains(u.pathExtension.lowercased())
        return add(title: u.deletingPathExtension().lastPathComponent, text: isMD ? Self.stripMarkdown(raw) : raw)
    }

    /// Markdown to plain reading text: headings, emphasis, list markers, links and code fences.
    static func stripMarkdown(_ s: String) -> String {
        var out: [String] = []
        for var l in s.components(separatedBy: .newlines) {
            if l.hasPrefix("```") { continue }
            l = l.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"^\s*([-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            l = l.replacingOccurrences(of: #"(\*\*|__|\*|_|`)"#, with: "", options: .regularExpression)
            out.append(l)
        }
        return out.joined(separator: "\n")
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(scripts) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: d, attributes: [.posixPermissions: 0o600])
    }
}

// MARK: - Options

enum PrompterSpeed: String, Codable, CaseIterable, Identifiable {
    case slow, normal, fast, sprint
    var id: String { rawValue }
    var ptPerSecond: Double { switch self { case .slow: 18; case .normal: 30; case .fast: 55; case .sprint: 85 } }
    var title: String { rawValue.capitalized }
}
enum PrompterCountdown: Int, Codable, CaseIterable { case off = 0, three = 3, five = 5, ten = 10 }
enum PrompterSize: String, Codable, CaseIterable { case s, m, l
    var font: CGFloat { switch self { case .s: 18; case .m: 24; case .l: 32 } }
    var line: CGFloat { (font * 1.4).rounded() }
}
enum PrompterVoice: String, Codable, CaseIterable { case off, basic, smart }

/// Context (Context.swift): IslandContext follows `Prompter.shared.running` (observable) to turn
/// Cinema, the equaliser and peeks off while prompting; this notification is posted as well.
extension Notification.Name { static let islandPrompterChanged = Notification.Name("app.glanceformac.glance.prompterChanged") }

// MARK: - Engine

@Observable @MainActor
final class Prompter {
    static let shared = Prompter()

    struct Line { let text: String; let firstWord: Int; let lastWord: Int }   // lastWord < firstWord: no words
    private(set) var lines: [Line] = []
    @ObservationIgnored private(set) var words: [String] = []
    private(set) var running = false
    private(set) var paused = false
    private(set) var countdown = 0
    private(set) var voiceStatus = ""
    /// Voice follow: speech is being heard (changes only when speech starts or stops).
    private(set) var hearing = false
    /// Smart recognition is really running (otherwise voice follow uses the voice level).
    private(set) var smartActive = false
    /// Last time a start was refused because a video is playing.
    private(set) var blockedNote: Date?
    private(set) var script: PrompterScript?
    private(set) var hoverPaused = false
    /// Clicked Play while the pointer is over the box: hovering doesn't pause until it leaves.
    @ObservationIgnored private var hoverOverride = false
    @ObservationIgnored private(set) var lastMatchedWord = -1
    @ObservationIgnored private(set) var lastFollowTarget: CGFloat?

    @ObservationIgnored private var window: PrompterWindowController?
    @ObservationIgnored private var voice: PrompterVoiceEngine?
    @ObservationIgnored var simulator: PrompterVoiceSimulator?
    @ObservationIgnored private var worker: PrompterMatchWorker?
    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var nudgeWork: DispatchWorkItem?
    /// Render-server scroller (set by the view).
    @ObservationIgnored weak var scroller: PrompterScroller.ScrollView?

    private var prefs: Prefs { AppSettings.shared.prefs }
    var lineHeight: CGFloat { prefs.prompterSize.line }
    var boxHeight: CGFloat { CGFloat(prefs.prompterHeight) }
    /// The reading line sits about a third of the way down the box.
    var readingY: CGFloat { max(30, (boxHeight * 0.3).rounded()) }
    var voiceMode: PrompterVoice { prefs.prompterVoice }

    // MARK: Start / stop

    /// Start the most recently edited script (for ⌘K / hot keys). Returns false if there is none.
    @discardableResult
    func startLatest() -> Bool {
        guard let s = PrompterLibrary.shared.scripts.max(by: { $0.date < $1.date }) else { return false }
        start(s); return true
    }

    func toggle(_ s: PrompterScript) { if running && script?.id == s.id { stop() } else { start(s) } }

    func start(_ s: PrompterScript) {
        // Cinema active (a video playing) means no Prompter: it would cover the film.
        guard IslandContext.shared.prompterAllowed else {
            blockedNote = Date()   // the Prompter page shows the reason inline
            if !IslandModel.shared.expanded {
                IslandModel.shared.enqueue(Peek(symbol: "text.viewfinder", title: "Prompter waits while a video plays", duration: 2.5))
            }
            return
        }
        stop()
        script = s
        layout(s.text)
        running = true
        paused = false
        hoverPaused = false; hoverOverride = false
        hearing = false; smartActive = false
        lastMatchedWord = -1; lastFollowTarget = nil
        worker = PrompterMatchWorker(words: words)
        IslandModel.shared.setExpanded(false)
        window = PrompterWindowController()
        window?.show()
        countdown = prefs.prompterCountdown.rawValue
        if countdown > 0 {
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { Prompter.shared.tickCountdown() }
            }
        }
        if voiceMode != .off { startVoice() }
        NotificationCenter.default.post(name: .islandPrompterChanged, object: nil)
    }

    private func tickCountdown() {
        guard running, countdown > 0 else { countdownTimer?.invalidate(); countdownTimer = nil; return }
        countdown -= 1
        if countdown == 0 { countdownTimer?.invalidate(); countdownTimer = nil; go() }
    }

    func stop() {
        let was = running
        running = false
        countdown = 0
        countdownTimer?.invalidate(); countdownTimer = nil
        nudgeWork?.cancel(); nudgeWork = nil
        voice?.stop(); voice = nil
        simulator?.stop(); simulator = nil
        worker = nil
        window?.close(); window = nil
        scroller = nil
        voiceStatus = ""; hearing = false; smartActive = false
        if was { NotificationCenter.default.post(name: .islandPrompterChanged, object: nil) }
    }

    /// Size, colour, width, height, mirror or sharing changed in Settings while running:
    /// rebuild the box in place, keeping the reading position (debounced for sliders).
    func restyle() {
        guard running else { return }
        restyleWork?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { Prompter.shared.restyleNow() } }
        restyleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }
    @ObservationIgnored private var restyleWork: DispatchWorkItem?
    @ObservationIgnored private var resumeWord: Int?

    private func restyleNow() {
        guard running, let s = script else { return }
        let li = currentLine
        let word = lines.indices.contains(li) ? lines[li].firstWord : 0
        layout(s.text)
        resumeWord = word
        window?.close(animated: false)
        scroller = nil
        window = PrompterWindowController()
        window?.show(animated: false)
    }

    // MARK: Motion

    private var maxOffset: CGFloat { CGFloat(max(0, lines.count - 1)) * lineHeight }

    /// Apply the current state: steady scroll from where the text is now, or hold still.
    /// Called only when something changes (start, pause, hover, speech starts/stops, speed).
    func go() {
        guard running, let sc = scroller else { return }
        if let w = resumeWord {
            resumeWord = nil
            let li = lines.firstIndex(where: { $0.lastWord >= w && $0.lastWord >= $0.firstWord }) ?? 0
            sc.hold(at: CGFloat(li) * lineHeight)
        }
        guard countdown == 0 else { return }
        let at = sc.currentOffset
        let stopped = paused || (hoverPaused && !hoverOverride)
        switch effectiveVoice {
        case .smart:
            // Words drive the text (followWord); only stop a glide when pausing.
            if stopped { sc.hold(at: at) }
            else if let t = lastFollowTarget, abs(t - at) > 1, !sc.isMoving { sc.glide(to: t, duration: glideDuration(t - at)) }
        case .basic:
            if !stopped && hearing { sc.scroll(from: at, to: maxOffset, speed: prefs.prompterSpeed.ptPerSecond) } else { sc.hold(at: at) }
        case .off:
            if !stopped { sc.scroll(from: at, to: maxOffset, speed: prefs.prompterSpeed.ptPerSecond) } else { sc.hold(at: at) }
        }
    }

    /// Smart only once recognition really runs; until then (or without permission) the voice level.
    var effectiveVoice: PrompterVoice {
        switch voiceMode {
        case .off: return .off
        case .basic: return .basic
        case .smart: return smartActive ? .smart : .basic
        }
    }

    func togglePause() {
        paused.toggle()
        if !paused && hoverPaused { hoverOverride = true }   // clicked Play while hovering: play now
        go()
    }

    func setHover(_ h: Bool) {
        guard h != hoverPaused else { return }
        hoverPaused = h
        if !h { hoverOverride = false }
        go()
    }

    func setSpeed(_ s: PrompterSpeed) {
        var p = AppSettings.shared.prefs; p.prompterSpeed = s; AppSettings.shared.prefs = p
        go()
    }

    /// Manual scrubbing (trackpad, scroll wheel, arrow keys). The scroll resumes a moment later.
    func nudge(_ dy: CGFloat) {
        guard let sc = scroller, running else { return }
        let o = min(maxOffset, max(0, sc.currentOffset + dy))
        sc.hold(at: o)
        lastFollowTarget = nil
        // Voice matching carries on from the place scrubbed to.
        let li = line(atOffset: o)
        if lines.indices.contains(li) { worker?.reset(to: lines[li].firstWord - 1) }
        nudgeWork?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { Prompter.shared.go() } }
        nudgeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
    }

    func line(atOffset o: CGFloat) -> Int { max(0, min(lines.count - 1, Int(o / lineHeight + 0.5))) }
    var currentLine: Int { line(atOffset: scroller?.currentOffset ?? 0) }
    var progress: Double { maxOffset > 0 ? Double((scroller?.currentOffset ?? 0) / maxOffset) : 0 }

    // MARK: Layout: greedy word wrap at the box width, keeping script word indices per line.

    func layout(_ text: String) {
        let font = NSFont.systemFont(ofSize: prefs.prompterSize.font, weight: .bold)
        let width = CGFloat(prefs.prompterWidth) - 56
        var out: [Line] = []
        var allWords: [String] = []
        for para in text.components(separatedBy: .newlines) {
            let ws = para.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if ws.isEmpty {
                // Keep a single blank line between paragraphs (none at the very start).
                if let last = out.last, !last.text.isEmpty { out.append(Line(text: "", firstWord: allWords.count, lastWord: allWords.count - 1)) }
                continue
            }
            var cur = "", first = allWords.count
            for w in ws {
                let candidate = cur.isEmpty ? w : cur + " " + w
                let size = (candidate as NSString).size(withAttributes: [.font: font])
                if size.width > width, !cur.isEmpty {
                    out.append(Line(text: cur, firstWord: first, lastWord: allWords.count - 1))
                    cur = w; first = allWords.count
                } else { cur = candidate }
                allWords.append(contentsOf: ScriptMatcher.tokens(w))
            }
            out.append(Line(text: cur, firstWord: first, lastWord: allWords.count - 1))
        }
        while let l = out.last, l.text.isEmpty { out.removeLast() }
        if out.isEmpty { out = [Line(text: "This script is empty.", firstWord: 0, lastWord: -1)] }
        lines = out
        words = allWords
    }

    // MARK: Voice follow

    private func startVoice() {
        guard !Env.noPermissions else { voiceStatus = "Voice follow is off in test mode"; return }
        let smart = voiceMode == .smart
        let v = PrompterVoiceEngine(smart: smart, contextualStrings: contextualStrings())
        v.onSpeaking = { s in DispatchQueue.main.async { MainActor.assumeIsolated { Prompter.shared.speaking(s) } } }
        v.onWords = { w in DispatchQueue.main.async { MainActor.assumeIsolated { Prompter.shared.heard(w) } } }
        v.onStatus = { s, smartOn in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                let p = Prompter.shared
                guard p.running else { return }
                p.voiceStatus = s; p.smartActive = smartOn; p.go()
            } }
        }
        voice = v
        voiceStatus = "Starting the microphone"
        v.start()
    }

    /// Script words that help recognition (longer, less common words), at most 100.
    private func contextualStrings() -> [String] {
        var seen = Set<String>(), out: [String] = []
        for l in lines { for w in l.text.split(separator: " ") {
            let c = String(w).trimmingCharacters(in: .punctuationCharacters)
            if c.count >= 6, seen.insert(c.lowercased()).inserted { out.append(c) }
            if out.count >= 100 { return out }
        } }
        return out
    }

    /// Simulated or real voice: speech started or stopped (already debounced by VoiceGate).
    func speaking(_ s: Bool) {
        guard running, s != hearing else { return }
        hearing = s
        if effectiveVoice == .basic { go() }
    }

    /// Simulated or real recogniser output (all words of the current utterance).
    func heard(_ hypothesis: [String], done: (@MainActor (Int?) -> Void)? = nil) {
        guard running, let worker else { done?(nil); return }
        worker.hear(hypothesis) { moved in
            if let w = moved { Prompter.shared.followWord(w) }
            done?(moved)
        }
    }

    func setSmartActive(_ on: Bool, status: String) { smartActive = on; voiceStatus = status; go() }

    /// Bring the spoken word to the reading line with a smooth catch-up glide.
    func followWord(_ w: Int) {
        guard running, let li = lines.lastIndex(where: { $0.firstWord <= w && $0.lastWord >= $0.firstWord }) else { return }
        lastMatchedWord = w
        let l = lines[li]
        let count = max(1, l.lastWord - l.firstWord + 1)
        let frac = Double(w - l.firstWord + 1) / Double(count)              // 0...1 through the line
        let target = max(0, min(maxOffset, CGFloat(li) * lineHeight + CGFloat(frac - 0.5) * lineHeight * 0.6))
        lastFollowTarget = target
        guard effectiveVoice == .smart, countdown == 0, !paused, !(hoverPaused && !hoverOverride), let sc = scroller else { return }
        let d = target - sc.currentOffset
        guard abs(d) > 1 else { return }
        sc.glide(to: target, duration: glideDuration(d))
    }

    /// Short glides for small steps, longer (never jumpy) ones for skips and repeats.
    private func glideDuration(_ d: CGFloat) -> Double { min(1.4, 0.45 + Double(abs(d)) / 420) }
}

// MARK: - Prompter window (directly under the pill; hidden from screen sharing)

final class PrompterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Esc stops, Space pauses, arrow keys scrub (whenever the box has the keyboard).
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown {
            let handled: Bool = MainActor.assumeIsolated {
                let pr = Prompter.shared
                switch Int(e.keyCode) {
                case 53: pr.stop()                              // Esc
                case 49: pr.togglePause()                       // Space
                case 126: pr.nudge(-pr.lineHeight)              // Up
                case 125: pr.nudge(pr.lineHeight)               // Down
                default: return false
                }
                return true
            }
            if handled { return }
        }
        super.sendEvent(e)
    }
}

@MainActor
final class PrompterWindowController {
    private(set) var panel: PrompterPanel?

    /// Right under the closed pill on the island's screen (the built-in display, under the camera).
    static func frame(width w: CGFloat, height h: CGFloat) -> NSRect {
        let f = NSApp.windows.first(where: { $0 is IslandPanel })?.screen?.frame ?? SafeScreen.primary.frame
        let pillBottom = f.maxY - IslandMetrics.closed.height
        return NSRect(x: (f.midX - w / 2).rounded(), y: pillBottom - 4 - h, width: w, height: h)
    }

    func show(animated: Bool = true) {
        let p = AppSettings.shared.prefs
        let final = Self.frame(width: CGFloat(p.prompterWidth), height: CGFloat(p.prompterHeight))
        let panel = PrompterPanel(contentRect: final, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // One level under the island, so the box slides out from beneath the pill.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // a live shadow is re-derived from content on every frame
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        // Not in screen sharing or recordings (unless turned off in Settings).
        panel.sharingType = p.prompterHideFromSharing ? .none : .readOnly
        panel.contentView = NSHostingView(rootView: PrompterView())
        // Drop down from under the pill.
        var start = final; start.origin.y += 18; start.size.height = final.height
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        // Take the keyboard so Esc / Space work straight away (the panel never activates Glance,
        // so the app in front stays active). Test instances don't, so they never take typing.
        if !Env.isolated { panel.makeKey() }
        if !animated { panel.setFrame(final, display: true); panel.alphaValue = 1 }
        else { NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.26
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1
        } }
        self.panel = panel
    }

    func close(animated: Bool = true) {
        guard let panel else { return }
        self.panel = nil
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

enum PrompterColour: String, CaseIterable {
    case white, yellow, green, cyan
    var ns: NSColor {
        switch self {
        case .white: .white
        case .yellow: NSColor(red: 1, green: 0.88, blue: 0.35, alpha: 1)
        case .green: NSColor(red: 0.5, green: 1, blue: 0.62, alpha: 1)
        case .cyan: NSColor(red: 0.5, green: 0.88, blue: 1, alpha: 1)
        }
    }
    var title: String { rawValue.capitalized }
}

struct PrompterView: View {
    private let pr = Prompter.shared
    private var hover: Bool { pr.hoverPaused }

    var body: some View {
        let p = AppSettings.shared.prefs
        ZStack(alignment: .top) {
            PrompterScroller(lines: pr.lines.map(\.text), size: p.prompterSize,
                             colour: PrompterColour(rawValue: p.prompterColour)?.ns ?? .white,
                             mirror: p.prompterMirror, readingY: pr.readingY)
            // Current-line highlight band: drawn by the scroller itself (same coordinates as the
            // reading window), so it can never sit half a line off the bright line.
            if pr.countdown > 0 {
                ZStack {
                    Color.black.opacity(0.55)
                    Text("\(pr.countdown)").font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                }
                .allowsHitTesting(false)
            }
            topBadges(p)
            if hover || pr.paused { controls(p) }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 12, style: .continuous))
        .onHover { h in pr.setHover(h) }
    }

    private func topBadges(_ p: Prefs) -> some View {
        HStack(spacing: 6) {
            if pr.voiceMode != .off {
                Image(systemName: pr.hearing ? "mic.fill" : "mic")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(pr.hearing ? Color.green : Color.white.opacity(0.4))
                    .help(pr.voiceStatus)
            }
            Spacer()
            if !p.prompterHideFromSharing {
                Text("Visible when sharing").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12).padding(.top, 7)
        .allowsHitTesting(false)
    }

    private func controls(_ p: Prefs) -> some View {
        VStack(spacing: 4) {
            if hover, !pr.voiceStatus.isEmpty {
                Text(pr.voiceStatus).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            HStack(spacing: 8) {
                Button { pr.togglePause() } label: {
                    Image(systemName: pr.paused ? "play.fill" : "pause.fill").frame(width: 18, height: 18)
                }.help(pr.paused ? "Play (Space)" : "Pause (Space)")
                ForEach(PrompterSpeed.allCases) { s in
                    Button { pr.setSpeed(s) } label: {
                        Text(s.title).font(.system(size: 10, weight: p.prompterSpeed == s ? .bold : .medium))
                            .foregroundStyle(p.prompterSpeed == s ? Color.black : Color.white.opacity(0.75))
                            .padding(.horizontal, 7).frame(height: 18)
                            .background(Capsule().fill(p.prompterSpeed == s ? Color.white : Color.white.opacity(0.08)))
                    }.help("\(Int(s.ptPerSecond)) pt a second")
                }
                Spacer(minLength: 4)
                Text(pr.paused ? "Paused" : "Line \(pr.currentLine + 1) of \(pr.lines.count)")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                Button { pr.stop() } label: { Image(systemName: "xmark").frame(width: 18, height: 18) }.help("Stop (Esc)")
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(Color(white: 0.15)))
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

/// The script is a stack of static text layers in one container layer. Core Animation moves the
/// container (and the progress bar) in the render server, so steady scrolling needs no work from
/// the app. A static gradient overlay fades the top and bottom and keeps the reading line brightest.
struct PrompterScroller: NSViewRepresentable {
    let lines: [String]
    let size: PrompterSize
    let colour: NSColor
    let mirror: Bool
    let readingY: CGFloat

    func makeNSView(context: Context) -> ScrollView {
        let v = ScrollView()
        v.configure(lines: lines, size: size, colour: colour, mirror: mirror, readingY: readingY)
        Prompter.shared.scroller = v
        DispatchQueue.main.async { Prompter.shared.go() }
        return v
    }
    func updateNSView(_ v: ScrollView, context: Context) {}

    /// Not flipped: layer y grows upwards. The container's anchor is its top-left corner.
    final class ScrollView: NSView {
        static let background = NSColor(white: 0.055, alpha: 1)
        private let container = CALayer()
        private let fade = CAGradientLayer()
        private let track = CALayer(), bar = CALayer()
        private var readingY: CGFloat = 54
        private var lineH: CGFloat = 30
        private var offsetNow: CGFloat = 0
        private var textLayers: [CATextLayer] = []
        private let band = CALayer()
        private var fontSize: CGFloat = 24
        private var mirror = false

        func configure(lines: [String], size: PrompterSize, colour: NSColor, mirror: Bool, readingY: CGFloat) {
            wantsLayer = true
            layer?.masksToBounds = true
            self.readingY = readingY; lineH = size.line; fontSize = size.font; self.mirror = mirror
            let font = NSFont.systemFont(ofSize: size.font, weight: .bold)
            let para = NSMutableParagraphStyle(); para.alignment = .center
            container.anchorPoint = CGPoint(x: 0, y: 1)
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            for t in lines {
                let tl = CATextLayer()
                tl.string = NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: para])
                tl.isWrapped = false
                tl.alignmentMode = .center
                tl.contentsScale = scale
                tl.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "transform": NSNull()]
                // Mirror for beam-splitter glass: each centred line flipped in place = the whole text flipped.
                if mirror { tl.transform = CATransform3DMakeScale(-1, 1, 1) }
                container.addSublayer(tl)
                textLayers.append(tl)
            }
            container.actions = ["position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(container)
            // A static overlay in the background colour (not a mask: a mask forces an offscreen
            // pass on every frame). Opaque at the edges, see-through on the reading line.
            let bg = Self.background
            fade.startPoint = CGPoint(x: 0.5, y: 1); fade.endPoint = CGPoint(x: 0.5, y: 0)   // location 0 = top
            fade.colors = [bg.cgColor, bg.withAlphaComponent(0.62).cgColor, bg.withAlphaComponent(0.38).cgColor, bg.withAlphaComponent(0).cgColor,
                           bg.withAlphaComponent(0).cgColor, bg.withAlphaComponent(0.38).cgColor, bg.withAlphaComponent(0.7).cgColor, bg.cgColor]
            fade.actions = ["position": NSNull(), "bounds": NSNull(), "locations": NSNull()]
            layer?.backgroundColor = bg.cgColor
            band.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
            band.cornerRadius = 8; band.cornerCurve = .continuous
            band.actions = ["position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(band)
            layer?.addSublayer(fade)
            // Progress: a thin bar along the bottom.
            track.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
            bar.backgroundColor = NSColor(white: 1, alpha: 0.55).cgColor
            bar.anchorPoint = CGPoint(x: 0, y: 0.5)
            for l in [track, bar] { l.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull()]; layer?.addSublayer(l) }
        }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let W = bounds.width, H = max(bounds.height, 1)
            fade.frame = bounds
            let top = Double(readingY / H), bot = Double((readingY + lineH) / H)
            let n = { (v: Double) in NSNumber(value: min(1, max(0, v))) }
            fade.locations = [0, n(top * 0.45), n(top - 0.04), n(top), n(bot), n(bot + 0.05), n(bot + (1 - bot) * 0.55), 1]
            band.frame = CGRect(x: 10, y: H - readingY - lineH, width: max(0, W - 20), height: lineH)   // layer y grows upwards
            let ch = CGFloat(textLayers.count) * lineH
            container.bounds = CGRect(x: 0, y: 0, width: W, height: ch)
            let textH = ceil(fontSize * 1.25)
            for (i, tl) in textLayers.enumerated() {
                tl.frame = CGRect(x: 28, y: ch - CGFloat(i + 1) * lineH + (lineH - textH) / 2, width: W - 56, height: textH)
            }
            track.frame = CGRect(x: 0, y: 0, width: W, height: 2)
            bar.bounds = CGRect(x: 0, y: 0, width: W, height: 2)
            bar.position = CGPoint(x: 0, y: 1)
            if container.animation(forKey: "scroll") == nil {
                container.position = CGPoint(x: 0, y: y(for: offsetNow))
                bar.transform = CATransform3DMakeScale(progress(offsetNow), 1, 1)
            }
            CATransaction.commit()
        }

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// Click: play / pause (and the box takes the keyboard, so Esc and Space work).
        override func mouseDown(with event: NSEvent) { if !Env.isolated { window?.makeKey() }; Prompter.shared.togglePause() }
        /// Trackpad / scroll wheel: scrub through the script.
        override func scrollWheel(with event: NSEvent) {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
            if abs(dy) > 0.01 { Prompter.shared.nudge(-dy) }
        }

        private var maxOffset: CGFloat { CGFloat(max(0, textLayers.count - 1)) * lineH }
        private func progress(_ o: CGFloat) -> CGFloat { maxOffset > 0 ? max(0.0001, min(1, o / maxOffset)) : 1 }
        private func y(for offset: CGFloat) -> CGFloat { bounds.height - readingY + offset }

        var isMoving: Bool { container.animation(forKey: "scroll") != nil }

        /// Offset currently on screen (from the presentation layer while animating).
        var currentOffset: CGFloat {
            guard bounds.height > 0, isMoving else { return offsetNow }
            let py = (container.presentation() ?? container).position.y
            return py - (bounds.height - readingY)
        }

        func hold(at offset: CGFloat) {
            offsetNow = offset
            container.removeAnimation(forKey: "scroll"); bar.removeAnimation(forKey: "scroll")
            CATransaction.begin(); CATransaction.setDisableActions(true)
            container.position = CGPoint(x: 0, y: y(for: offset))
            bar.transform = CATransform3DMakeScale(progress(offset), 1, 1)
            CATransaction.commit()
        }

        func scroll(from: CGFloat, to: CGFloat, speed: Double) {
            guard to > from + 0.5, speed > 0 else { hold(at: from); return }
            animate(from: from, to: to, duration: Double(to - from) / speed, timing: CAMediaTimingFunction(name: .linear))
        }

        func glide(to offset: CGFloat, duration: Double) {
            // Ease out only: a glide that starts while the text is moving never stops first.
            animate(from: currentOffset, to: offset, duration: duration, timing: CAMediaTimingFunction(controlPoints: 0.25, 0.6, 0.35, 1))
        }

        private func animate(from: CGFloat, to: CGFloat, duration: Double, timing: CAMediaTimingFunction) {
            offsetNow = to
            let a = CABasicAnimation(keyPath: "position.y")
            a.fromValue = y(for: from); a.toValue = y(for: to)
            a.duration = duration
            a.timingFunction = timing
            // Text scrolls at most ~85 pt/s, so 30 fps is smooth and halves the compositing work.
            a.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
            let b = CABasicAnimation(keyPath: "transform.scale.x")
            b.fromValue = progress(from); b.toValue = progress(to)
            b.duration = duration; b.timingFunction = timing
            b.preferredFrameRateRange = a.preferredFrameRateRange
            CATransaction.begin(); CATransaction.setDisableActions(true)
            container.position = CGPoint(x: 0, y: y(for: to))
            bar.transform = CATransform3DMakeScale(progress(to), 1, 1)
            CATransaction.commit()
            container.add(a, forKey: "scroll")
            bar.add(b, forKey: "scroll")
        }
    }
}

// MARK: - Library / editor page inside the expanded island

struct PrompterPage: View {
    let theme: Theme
    private let lib = PrompterLibrary.shared
    @State private var editing: PrompterScript?
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var confirmDelete: UUID?
    @State private var note = ""

    var body: some View {
        if let s = editing {
            PrompterEditor(theme: theme, script: s) { editing = nil }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Prompter").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.primary)
                    Text(note.isEmpty ? "Shows under the island, hidden from screen sharing" : note)
                        .font(.system(size: 11)).foregroundStyle(theme.tertiary).lineLimit(1)
                    Spacer()
                    pill("plus", "New") { editing = lib.add() }
                    pill("doc.on.clipboard", "Paste") {
                        if lib.pasteNew() == nil { flash("The clipboard has no text") }
                    }
                    pill("square.and.arrow.down", "Import") { lib.importFile() }
                }
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if lib.scripts.isEmpty {
                            Text("No scripts yet. Make a new one, paste text, or import a .txt or .md file.")
                                .font(.system(size: 11)).foregroundStyle(theme.tertiary).padding(8)
                        }
                        ForEach(lib.scripts) { s in row(s) }
                    }
                }
            }
            .padding(.bottom, 12)
            .onAppear { takeEditRequest() }
            .onChange(of: lib.editRequest) { _, _ in takeEditRequest() }
            .onChange(of: Prompter.shared.blockedNote) { _, _ in flash("Prompter waits while a video plays") }
        }
    }

    private func takeEditRequest() {
        guard let id = lib.editRequest else { return }
        lib.editRequest = nil
        editing = lib.scripts.first { $0.id == id }
    }

    private static func shortDate(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened) : d.formatted(.dateTime.day().month(.abbreviated))
    }

    private func row(_ s: PrompterScript) -> some View {
        let running = Prompter.shared.running && Prompter.shared.script?.id == s.id
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                if renaming == s.id {
                    TextField("Title", text: $renameText)
                        .textFieldStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.primary)
                        .onSubmit { lib.rename(s, to: renameText); renaming = nil }
                        .onExitCommand { renaming = nil }
                } else {
                    Text(s.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.primary).lineLimit(1)
                        .onTapGesture(count: 2) { renameText = s.title; renaming = s.id }
                }
                Text(s.preview).font(.system(size: 10)).foregroundStyle(theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(Self.shortDate(s.date)).font(.system(size: 10)).foregroundStyle(theme.tertiary).lineLimit(1).fixedSize()
            Button { Prompter.shared.toggle(s) } label: {
                Image(systemName: running ? "stop.fill" : "play.fill").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.onAccent).frame(width: 28, height: 22).background(Capsule().fill(theme.accent))
            }.buttonStyle(.plain).help(running ? "Stop" : "Start")
            iconButton(renaming == s.id ? "checkmark" : "character.cursor.ibeam", renaming == s.id ? "Save name" : "Rename") {
                if renaming == s.id { lib.rename(s, to: renameText); renaming = nil } else { renameText = s.title; renaming = s.id }
            }
            iconButton("pencil", "Edit") { editing = s }
            if confirmDelete == s.id {
                Button { lib.delete(s); confirmDelete = nil } label: {
                    Text("Delete").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).frame(height: 20).background(Capsule().fill(Color.red.opacity(0.85)))
                }.buttonStyle(.plain)
            } else {
                iconButton("trash", "Delete") {
                    confirmDelete = s.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if confirmDelete == s.id { confirmDelete = nil } }
                }
            }
        }
        .padding(.horizontal, 10).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card))
        .contextMenu {
            Button(running ? "Stop" : "Start") { Prompter.shared.toggle(s) }
            Button("Rename") { renameText = s.title; renaming = s.id }
            Button("Edit") { editing = s }
            Divider()
            Button("Delete", role: .destructive) { lib.delete(s) }
        }
    }

    private func flash(_ t: String) {
        note = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if note == t { note = "" } }
    }

    private func iconButton(_ sym: String, _ help: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) { Image(systemName: sym).font(.system(size: 11)).foregroundStyle(theme.secondary).frame(width: 20, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(help)
    }

    private func pill(_ sym: String, _ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            HStack(spacing: 4) { Image(systemName: sym).font(.system(size: 10, weight: .semibold)); Text(t).font(.system(size: 11, weight: .medium)) }
                .foregroundStyle(theme.primary).padding(.horizontal, 10).frame(height: 24).background(Capsule().fill(theme.card))
        }.buttonStyle(PressScaleStyle())
    }
}

struct PrompterEditor: View {
    let theme: Theme
    @State var script: PrompterScript
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Title", text: $script.title).textFieldStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primary)
                Spacer()
                Text("\(script.text.split(whereSeparator: { $0.isWhitespace }).count) words").font(.system(size: 10)).foregroundStyle(theme.tertiary)
                Button("Paste") {
                    if let t = Env.pasteboard.string(forType: .string) { script.text += (script.text.isEmpty ? "" : "\n") + t }
                }.buttonStyle(.borderless).font(.system(size: 11))
                Button("Done") { PrompterLibrary.shared.update(script); done() }.buttonStyle(.borderless).font(.system(size: 11, weight: .semibold))
                Button { PrompterLibrary.shared.update(script); Prompter.shared.start(script) } label: {
                    Label("Start", systemImage: "play.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 10).frame(height: 24).background(Capsule().fill(theme.accent))
                }.buttonStyle(.plain)
            }
            TextEditor(text: $script.text)
                .font(.system(size: 12)).scrollContentBackground(.hidden)
                .padding(6).background(RoundedRectangle(cornerRadius: 10).fill(theme.card))
        }
        .padding(.bottom, 12)
        .onDisappear { PrompterLibrary.shared.update(script) }
    }
}
