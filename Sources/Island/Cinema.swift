import AppKit
import SwiftUI
import Observation
import os

/// Cinema mode, driven by the Glance for Mac Chrome extension (no screen capture).
/// The extension sends only: region colours, band levels, play state, full screen and the
/// site's domain. Glance never receives images, URLs beyond the domain, or page content.
@Observable @MainActor
final class ChromeAmbilight {
    static let shared = ChromeAmbilight()
    static let log = Logger(subsystem: "app.glanceformac.glance", category: "cinema")

    private(set) var playing = false
    private(set) var method = "none"         // direct | snapshot | protected | none
    private(set) var audio = "no-audio"      // ok | no-audio
    private(set) var fullscreen = false
    private(set) var domain = ""
    private(set) var connected = false
    @ObservationIgnored private(set) var lastUpdate = Date.distantPast
    @ObservationIgnored private(set) var frames = 0
    @ObservationIgnored private(set) var bandUpdates = 0
    @ObservationIgnored private(set) var lastColours = "-"
    @ObservationIgnored private(set) var lastBands = "-"
    @ObservationIgnored private(set) var lastDisplay = "-"
    @ObservationIgnored private var smooth: [SIMD3<Double>] = Array(repeating: SIMD3(0.3, 0.3, 0.3), count: 4)
    @ObservationIgnored private var lastFrameTime = Date()
    @ObservationIgnored private var lastColourApply = Date.distantPast
    @ObservationIgnored private var lastPushed: [SIMD3<Double>] = []
    @ObservationIgnored private var staleTimer: Timer?
    @ObservationIgnored private var wasEngaged = false
    @ObservationIgnored private var lastIntroKey = ""
    @ObservationIgnored private var lastEngagedEnd = Date.distantPast

    /// Cinema glow is showing.
    var engaged: Bool {
        guard IslandContext.shared.cinemaAllowed else { return false }   // Prompter running: Cinema off
        return engagedRaw
    }
    private var engagedRaw: Bool {
        AppSettings.shared.prefs.cinemaExtension && playing && method != "protected" && method != "none"
            && Date().timeIntervalSince(lastUpdate) < 30   // covered windows send rarely: hold the last colours
    }

    // In-pill Cinema state (UI-facing values change at most about once a second).
    private(set) var title = ""
    @ObservationIgnored private(set) var mediaId = ""
    @ObservationIgnored private(set) var duration: Double?
    @ObservationIgnored private(set) var lastSpectrum = "-"
    private(set) var progress: Double?            // 0...1, nil for live / unknown duration
    private(set) var endsAt: Date?
    private(set) var pausedAt: Date?
    var titleCardUntil: Date?
    var endsCardUntil: Date?
    @ObservationIgnored private weak var link: ClaudeConnection?
    @ObservationIgnored private var lastUIUpdate = Date.distantPast
    @ObservationIgnored private var lastEndsShown = Date.distantPast
    @ObservationIgnored private var prevBass: Double = 0
    @ObservationIgnored private var lastBandsAt = Date.distantPast
    /// The video ended or its tab closed: Cinema leaves with the outro (not on pause or tab switch).
    @ObservationIgnored private var outroNext = false
    @ObservationIgnored private var spectrumTimes: [Date] = []
    @ObservationIgnored private(set) var beatCount = 0
    /// Spectrum messages received per second over the last 5 s (diagnostics).
    var spectrumRate: Double { Double(spectrumTimes.filter { Date().timeIntervalSince($0) < 5 }.count) / 5 }
    /// Audio reported "ok" but no levels for 2 s: treat as no audio (idle wave, never frozen bars).
    private var bandsStale: Bool { Date().timeIntervalSince(lastBandsAt) > 2 }
    @ObservationIgnored private var lastTitleShown = ""

    /// A Chrome video is the thing on screen (playing, or paused within the intermission window).
    var videoContext: Bool { connected && (playing || intermission) }
    /// A paused (not ended) Cinema video stays on the pill as a reminder, whichever app or tab
    /// is in front, until it resumes, ends, its tab closes or navigates, it is dismissed, or
    /// 30 minutes pass (then only a tiny paused dot remains until dismissed).
    var intermission: Bool {
        guard AppSettings.shared.prefs.cinemaIntermission, !playing, pausedAt != nil, !intermissionDismissed else { return false }
        return !intermissionLong
    }
    var pausedDot: Bool {
        AppSettings.shared.prefs.cinemaIntermission && connected && !playing && pausedAt != nil && !intermissionDismissed && intermissionLong
    }
    private(set) var intermissionDismissed = false
    private(set) var intermissionLong = false

    func dismissIntermission() {
        withAnimation(.easeInOut(duration: 0.3)) { intermissionDismissed = true }
        IslandModel.shared.hoverControls = false
    }
    /// Resume from the pill: play that tab's video (and, if asked, bring its tab to the front).
    func resumeFromIntermission(focusTab: Bool) {
        command("play")
        if focusTab { command("focus") }
        // A video playing in a background tab isn't followed, so don't wait for its "playing".
        withAnimation(.easeInOut(duration: 0.3)) { clearPause() }
        IslandModel.shared.hoverControls = false
    }
    private func clearPause() {
        pausedAt = nil; intermissionLong = false; intermissionDismissed = false
    }
    /// The Chrome connection went away (Chrome quit): nothing to remind about any more.
    func linkClosed(_ l: ClaudeConnection) {
        guard l === link else { return }
        link = nil; connected = false; playing = false; clearPause(); progress = nil
        transitionCheck()
    }

    @ObservationIgnored private var linkLastPlaying = Date.distantPast

    /// Commands go only to the Chrome connection whose video Glance is following.
    @ObservationIgnored private var titlesSent: (ObjectIdentifier, Bool)?
    /// The extension sends video titles only while the Title card is on (privacy: less data).
    func syncTitlePreference() {
        guard let link else { return }
        let on = AppSettings.shared.prefs.cinemaTitle
        if let t = titlesSent, t.0 == ObjectIdentifier(link), t.1 == on { return }
        titlesSent = (ObjectIdentifier(link), on)
        link.sendLine(["type": "command", "cmd": on ? "titles-on" : "titles-off"])
    }

    func command(_ cmd: String) {
        link?.sendLine(["type": "command", "cmd": cmd])
        Self.log.info("command \(cmd, privacy: .public)")
    }

    func receive(_ m: [String: Any], link l: ClaudeConnection? = nil) {
        guard AppSettings.shared.prefs.cinemaExtension else { return }
        // Follow ONE source (one Chrome connection). Another connection only takes over when it
        // starts playing and the followed one hasn't played for a moment. Never mix sources.
        if let l, l !== link {
            let startsPlaying = (m["state"] as? String) == "playing"
            let followedIdle = link == nil || Date().timeIntervalSince(linkLastPlaying) > 2
            guard startsPlaying && followedIdle else { return }
            link = l
            Self.log.info("following a new Chrome connection")
        }
        if (m["state"] as? String) == "playing" { linkLastPlaying = Date() }
        syncTitlePreference()
        if (m["type"] as? String) == "result" {
            if let r = m["result"] as? String, r == "NotAllowedError" || r == "error" || r == "unsupported" {
                IslandModel.shared.enqueue(Peek(symbol: "exclamationmark.circle", title: "This page didn't allow that", duration: 2))
            }
            return
        }
        lastUpdate = Date()
        let state = m["state"] as? String ?? ""
        // Intermission: remember when it paused; a resume flashes the glow.
        if state == "paused", playing || pausedAt == nil { pausedAt = Date(); intermissionLong = false; intermissionDismissed = false }
        if state == "playing", pausedAt != nil {
            if intermission { IslandModel.shared.flash(.timer, seconds: 0.6) }
            clearPause()
        }
        if state == "ended" { clearPause() }
        if (state == "ended" || state == "closed"), wasEngaged || playing { outroNext = true }
        if state == "background" || state == "closed" {   // playing tab switched away, or tab closed/navigated
            playing = false; clearPause()
            AudioBarsRegistry.idle()
            transitionCheck()
            return
        }
        if state == "away" {                  // paused tab no longer in front: keep the reminder
            playing = false
            transitionCheck()
            return
        }
        updateMedia(m)
        if !connected { connected = true; Self.log.info("extension connected") }
        let newPlaying = (m["state"] as? String) == "playing"
        if newPlaying != playing { playing = newPlaying; Self.log.info("chrome video \(newPlaying ? "playing" : "paused", privacy: .public)") }
        if let v = m["method"] as? String, v != method { method = v; Self.log.info("method \(v, privacy: .public)") }
        if let v = m["audio"] as? String, v != audio { audio = v }
        if let v = m["fullscreen"] as? Bool, v != fullscreen { fullscreen = v }
        if let v = m["domain"] as? String, v != domain { domain = v }

        // Colours: [left, right, top, bottom, centre] as [r,g,b] 0...255. Applied at most 5 Hz.
        // Anything malformed (short arrays, NaN, huge numbers) is clamped or dropped, never trusted.
        if let c = Self.sanitizedColours(m["colors"]), newPlaying, method != "protected", IslandContext.shared.cinemaAllowed,
           Date().timeIntervalSince(lastColourApply) >= Power.shared.colourInterval {
            lastColourApply = Date()
            frames += 1
            let left = c[0], right = c[1], top = c[2], bottom = c[3], centre = c[4]
            func v(_ a: [Double]) -> SIMD3<Double> { SIMD3(a[0] / 255, a[1] / 255, a[2] / 255) }
            // Glow order: top, right, bottom, left. The bottom of the glow faces the picture's centre.
            let targets = [v(top), v(right), (v(bottom) + v(centre)) / 2, v(left)]
            let now = Date()
            let dt = min(now.timeIntervalSince(lastFrameTime), 0.5)
            lastFrameTime = now
            // Light smoothing (the render server also interpolates between updates);
            // scene cuts (big jumps) follow at once.
            var sceneCut = false
            for i in 0..<4 {
                let diff = targets[i] - smooth[i]
                let dist = (diff * diff).sum().squareRoot()
                if dist > 0.3 { sceneCut = true }
                let tau = dist > 0.3 ? 0.03 : 0.12
                smooth[i] += diff * (1 - exp(-dt / tau))
            }
            lastColours = c.prefix(5).map { String(format: "#%02X%02X%02X", Int($0[0]), Int($0[1]), Int($0[2])) }.joined(separator: ",")
            let brightness = smooth.map { max($0.x, $0.y, $0.z) }.reduce(0, +) / 4
            // Skip all layer work when the colours barely changed.
            let delta = zip(smooth, lastPushed).map { (($0 - $1) * ($0 - $1)).sum() }.max() ?? 1
            guard lastPushed.isEmpty || delta > 0.0004 else { transitionCheck(); return }
            lastPushed = smooth
            let cols = smooth.map { Self.vivid($0) }
            lastDisplay = cols.map { c -> String in
                let r = c.usingColorSpace(.sRGB) ?? c
                return String(format: "#%02X%02X%02X", Int(r.redComponent * 255), Int(r.greenComponent * 255), Int(r.blueComponent * 255))
            }.joined(separator: ",")
            GlowRegistry.push(colors: cols, intensity: Self.intensity(brightness), cut: sceneCut)
            if AppSettings.shared.prefs.cinemaInterior { InteriorRegistry.push(left: cols[3], right: cols[1], brightness: brightness) }
            EqualiserRegistry.colours([cols[3], cols[0], cols[2], cols[1]])   // left, top, centre, right
            TouchBarGlow.shared.update(colors: [cols[3], cols[0], cols[2], cols[1]])
        }
        if let b = Self.levels(m["bands"], max: 64), b.count >= 4, newPlaying {
            // Bass "thump": a quick glow-intensity pulse on a sharp bass rise.
            if b[0] - prevBass > 0.25 && b[0] > 0.6, AppSettings.shared.prefs.cinemaWave { GlowRegistry.thump(); EqualiserRegistry.thump() }
            prevBass = b[0]
            if let bt = m["beats"] as? Int { beatCount = bt }
            if let spec = Self.levels(m["spectrum"], max: 128), spec.count >= 8 {
                spectrumTimes.append(Date()); if spectrumTimes.count > 64 { spectrumTimes.removeFirst(spectrumTimes.count - 64) }
                // During the intro/outro the bars are hidden: skip the work (keeps every frame free).
                if IslandModel.shared.celebration?.kind.isCinemaCA != true {
                    EqualiserRegistry.push(spec.map { Float($0) }, interval: 1 / ClaudeConnection.maxRate)
                    TouchBarGlow.shared.levels(spec.map { Float($0) })
                }
                lastSpectrum = spec.map { String(format: "%.2f", $0) }.joined(separator: ",")
            }
            else { EqualiserRegistry.push4(b.prefix(4).map { Float($0) }) }
            bandUpdates += 1
            lastBandsAt = Date()
            lastBands = b.prefix(4).map { String(format: "%.2f", $0) }.joined(separator: ",")
            if let spec = Self.levels(m["spectrum"], max: 128), spec.count >= 28 {
                // 28 bands -> 5 bars: bass, low-mid, mid, high-mid, treble.
                let groups = [0..<6, 6..<12, 12..<18, 18..<23, 23..<28]
                AudioBarsRegistry.push(groups.map { g in
                    let v = spec[g]; let mx = v.max() ?? 0, mean = v.reduce(0, +) / Double(v.count)
                    return Float(0.6 * mx + 0.4 * mean)
                })
            } else {
                let b4 = b.prefix(4).map { Float($0) }
                AudioBarsRegistry.push([b4[0], b4[1], (b4[1] + b4[2]) / 2, b4[2], b4[3]])
            }
        } else if audio != "ok" || bandsStale {
            AudioBarsRegistry.idle()
            if newPlaying { EqualiserRegistry.idle() }
            // Diagnostics: no audio data means no levels (nothing stale left behind).
            lastBands = "-"; lastSpectrum = "-"
        }
        if !newPlaying {
            EqualiserRegistry.flat()
            // Paused/stopped: levels go to zero (nothing frozen).
            lastBands = "0.00,0.00,0.00,0.00"
            if lastSpectrum != "-" { lastSpectrum = Array(repeating: "0.00", count: 28).joined(separator: ",") }
        }
        transitionCheck()
        if staleTimer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { ChromeAmbilight.shared.staleCheck() } }
            t.tolerance = 0.3
            RunLoop.main.add(t, forMode: .common)
            staleTimer = t
        }
    }

    private func updateMedia(_ m: [String: Any]) {
        let now = Date()
        let t = m["title"] as? String ?? ""
        if let id = m["mediaId"] as? String, !id.isEmpty, id != mediaId {
            let previous = mediaId
            mediaId = id
            // One video replaced another while Cinema stayed on (site to site, next episode):
            // greet the new one like a fresh start.
            if !previous.isEmpty, wasEngaged, (m["state"] as? String) == "playing" {
                Self.log.info("new media while engaged")
                wasEngaged = false
                DispatchQueue.main.async { self.transitionCheck() }
            }
        }
        duration = m["duration"] as? Double
        let state = m["state"] as? String ?? ""
        // Title card when a (new) video starts playing.
        let titleKey = mediaId.isEmpty ? t : mediaId
        if state == "playing", !t.isEmpty, titleKey != lastTitleShown, AppSettings.shared.prefs.cinemaTitle {
            lastTitleShown = titleKey
            title = t
            let introComing = AppSettings.shared.prefs.cinemaIntro && !wasEngaged && mediaId != lastIntroKey && (duration ?? 999) >= 90
            showTitleCard(after: introComing ? IntroH.duration : 0)
        }
        // Progress + "Ends 11:42 PM": refresh the UI at most once a second.
        guard now.timeIntervalSince(lastUIUpdate) >= 1 else { return }
        lastUIUpdate = now
        if !t.isEmpty, t != title { title = t }
        if let time = m["time"] as? Double, let dur = m["duration"] as? Double, dur > 0, (m["live"] as? Bool) != true {
            progress = min(max(time / dur, 0), 1)
            let rate = max((m["rate"] as? Double) ?? 1, 0.1)
            endsAt = now.addingTimeInterval((dur - time) / rate)
            // Every ~10 minutes, briefly show when it ends.
            if state == "playing", now.timeIntervalSince(lastEndsShown) > 600 { showEnds() }
        } else {
            progress = nil; endsAt = nil
        }
    }

    func showTitleCard(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.easeInOut(duration: 0.5)) { self.titleCardUntil = Date().addingTimeInterval(3) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.05) { withAnimation(.easeInOut(duration: 0.6)) { self.titleCardUntil = nil } }
        }
    }

    func showEnds() {
        guard endsAt != nil, AppSettings.shared.prefs.cinemaProgress else { return }
        lastEndsShown = Date()
        withAnimation(.easeInOut(duration: 0.4)) { endsCardUntil = Date().addingTimeInterval(3) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.05) { withAnimation(.easeInOut(duration: 0.5)) { self.endsCardUntil = nil } }
    }

    /// No messages for a while (tab closed, Chrome quit): stop the glow.
    private func staleCheck() {
        if let p = pausedAt, !intermissionLong, Date().timeIntervalSince(p) >= 30 * 60 {
            withAnimation(.easeInOut(duration: 0.4)) { intermissionLong = true }
        }
        // A playing video sends at least once a second (a 1 s heartbeat even when its window is
        // covered), so 6 s of silence means its page is gone: stop following it. (It was 30 s, and
        // the 12 s "disconnected" check sat inside that block, so it could never act sooner.)
        // A paused video sends rarely (background pages are throttled): never time it out.
        let silent = Date().timeIntervalSince(lastUpdate)
        if pausedAt == nil, silent > 6 {
            if playing { playing = false }
            AudioBarsRegistry.idle()
            if silent > 12 {
                connected = false; clearPause(); progress = nil
                staleTimer?.invalidate(); staleTimer = nil
            }
        }
        transitionCheck()
    }

    func transitionCheck() {
        let now = engaged
        guard now != wasEngaged else { return }
        wasEngaged = now
        Self.log.info("cinema \(now ? "on" : "off", privacy: .public)")
        if now {
            // Intro once per video (same title/site), or after a break of more than 10 minutes;
            // resuming or coming back to the tab is just a quick glow flash.
            // Intro once per media item (tab + media identity), or after a break > 10 min.
            // Short-form videos (< 90 s, e.g. TikTok/Shorts swipes) only get a flash.
            let key = mediaId.isEmpty ? domain : mediaId
            let longBreak = Date().timeIntervalSince(lastEngagedEnd) > 600
            let shortForm = (duration ?? 999) < 90
            if AppSettings.shared.prefs.cinemaIntro && !shortForm && (key != lastIntroKey || longBreak) {
                lastIntroKey = key
                Self.log.info("intro (\(key, privacy: .public))")
                IslandModel.shared.celebrate(.cinemaIntro)
            } else {
                Self.log.info("flash (\(shortForm ? "short-form" : "same media", privacy: .public))")
                IslandModel.shared.flash(.timer, seconds: 0.6)
            }
            TouchBarGlow.shared.begin()
        } else {
            lastEngagedEnd = Date()
            if outroNext, AppSettings.shared.prefs.cinemaIntro {
                outroNext = false
                Self.log.info("outro")
                IslandModel.shared.celebrate(.cinemaOutro)
                TouchBarGlow.shared.endWithOutro()
            } else {
                outroNext = false
                GlowRegistry.refreshFromConfig()
                TouchBarGlow.shared.end()
            }
            IslandContext.shared.reevaluate()   // celebrations held during the film
        }
    }

    /// Settings toggle turned on during playback: play the intro.
    func toggled(on: Bool) {
        wasEngaged = false
        if on { transitionCheck() } else { GlowRegistry.refreshFromConfig(); TouchBarGlow.shared.end() }
    }

    /// Glow strength: Rich = deep, saturated, bright (x1.6 saturation with a floor, rim never
    /// below ~75% brightness); only genuinely black scenes dim the glow (via intensity).
    /// Sound levels: at most `max` finite values, each clamped to 0...1, or nil.
    static func levels(_ raw: Any?, max limit: Int) -> [Double]? {
        guard let list = raw as? [Any], !list.isEmpty, list.count <= limit else { return nil }
        return list.map { x in
            guard let d = (x as? NSNumber)?.doubleValue, d.isFinite else { return 0 }
            return min(max(d, 0), 1)
        }
    }

    /// Exactly five [r, g, b] triples, each channel finite and clamped to 0...255, or nil.
    static func sanitizedColours(_ raw: Any?) -> [[Double]]? {
        guard let list = raw as? [Any], list.count >= 5 else { return nil }
        var out: [[Double]] = []
        for item in list.prefix(5) {
            guard let rgb = item as? [Any], rgb.count >= 3 else { return nil }
            var ch: [Double] = []
            for x in rgb.prefix(3) {
                guard let d = (x as? NSNumber)?.doubleValue, d.isFinite else { return nil }
                ch.append(min(max(d, 0), 255))
            }
            out.append(ch)
        }
        return out
    }

    static func vivid(_ v: SIMD3<Double>) -> NSColor {
        let c = NSColor(srgbRed: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        switch MainActor.assumeIsolated({ AppSettings.shared.prefs.glowStrength }) {
        case .rich:
            // Rich but faithful: real colours get a proportional boost, pastels stay pastel
            // (just brighter), greys stay neutral; brightness follows the scene (floor 0.45).
            // The extension already picks each region's most vivid colour, so only a gentle
            // curve here: no change below 0.3 saturation; above, a quarter of the way to full.
            // Value capped at 0.95, so nothing is forced to a pure primary.
            // Pastels and creams (saturation <= 0.3) keep their saturation: only brighter.
            let sat: CGFloat = s > 0.3 ? s + (1 - s) * 0.4 : s
            // Brightness floor ramps in from dark scenes, so a night sky stays a night sky
            // (dimmed further via intensity) while ordinary scenes glow brightly.
            let floor = 0.62 * min(1, max(0, (b - 0.12) / 0.28))
            return NSColor(hue: h, saturation: min(sat, 1), brightness: min(1, max(floor, b * 1.35)), alpha: 1)
        case .normal:
            return NSColor(hue: h, saturation: min(s * 1.4, 1), brightness: s > 0.1 ? max(0.7, min(b * 1.3, 1)) : min(b * 1.2 + 0.1, 0.9), alpha: 1)
        case .subtle:
            return NSColor(hue: h, saturation: min(s * 1.15, 1), brightness: min(b * 1.1, 0.9), alpha: 1)
        }
    }

    static func intensity(_ sceneBrightness: Double) -> CGFloat {
        let rich = MainActor.assumeIsolated({ AppSettings.shared.prefs.glowStrength }) == .rich
        if sceneBrightness < 0.06 { return rich ? 0.35 : 0.2 }             // true black scene: dim gracefully
        if sceneBrightness < 0.2 { return CGFloat((rich ? 0.35 : 0.2) + (sceneBrightness - 0.06) / 0.14 * (rich ? 0.55 : 0.4)) } // dark scenes stay darker
        let richValue: Double = 0.92 + 0.08 * min(sceneBrightness * 1.5, 1)
        let normalValue: Double = 0.35 + 0.65 * min(sceneBrightness * 1.3, 1)
        return CGFloat(rich ? richValue : normalValue)
    }

    /// glance://cinema-status -> ~/Library/Caches/Glance/cinema-status.txt
    func writeStatus() {
        let lines = [
            "time: \(Date())",
            "prefs.cinemaExtension: \(AppSettings.shared.prefs.cinemaExtension)",
            "extension connected: \(connected) lastUpdate: \(lastUpdate == .distantPast ? "never" : "\(String(format: "%.1f", Date().timeIntervalSince(lastUpdate)))s ago")",
            "domain: \(domain) playing: \(playing) method: \(method) audio: \(audio) fullscreen: \(fullscreen)",
            "engaged (glow following video): \(engaged)",
            "frames: \(frames) bandUpdates: \(bandUpdates) spectrumUpdates/s: \(String(format: "%.1f", spectrumRate)) (applied/s: \(String(format: "%.1f", EqualiserRegistry.appliedRate)))",
            "glowStrength (effective): \(AppSettings.shared.prefs.glowStrength.rawValue)",
            "title: \(title) progress: \(progress.map { String(format: "%.3f", $0) } ?? "-") endsAt: \(endsAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "-")",
            "intermission: \(intermission) pausedAt: \(pausedAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "-") hoverControls: \(IslandModel.shared.hoverControls)",
            "rawColours from extension (left,right,top,bottom,centre): \(lastColours)",
            "displayColours after boost (glow top,right,bottom,left): \(lastDisplay)",
            "lastBands: \(lastBands)",
            "spectrum (28 bands, bass -> treble): \(lastSpectrum)",
            "mediaId: \(mediaId) duration: \(duration.map { String(format: "%.0f", $0) } ?? "-")",
            "NowPlaying: \(NowPlaying.shared.bundleID) isPlaying=\(NowPlaying.shared.isPlaying)",
            "touchBar: \(TouchBarGlow.shared.statusLine)",
            "beats (bass transients detected by the extension): \(beatCount)",
        ]
        let dir = Env.cachesBase.appendingPathComponent("Glance", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = DebugChannel.tag != nil ? DebugChannel.snapshotDir.appendingPathComponent("cinema-status.txt")
            : dir.appendingPathComponent(Env.isolated ? "cinema-status-test.txt" : "cinema-status.txt")
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    // MARK: Preview (simulated colours, nothing captured)

    @ObservationIgnored private var simTimer: Timer?
    private(set) var simulating = false

    func previewSimulated(seconds: Double = 8) {
        simTimer?.invalidate()
        simulating = true
        IslandModel.shared.setExpanded(false)
        IslandModel.shared.celebrate(.cinemaIntro)
        TouchBarGlow.shared.begin()
        let start = Date()
        let t = Timer(timeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                let e = Date().timeIntervalSince(start)
                if e > seconds {
                    timer.invalidate()
                    ChromeAmbilight.shared.simulating = false
                    GlowRegistry.refreshFromConfig()
                    TouchBarGlow.shared.end()
                    return
                }
                func hue(_ h: Double, _ v: Double) -> NSColor { NSColor(hue: CGFloat(h.truncatingRemainder(dividingBy: 1)), saturation: 0.85, brightness: CGFloat(v), alpha: 1) }
                let cols = [hue(e * 0.05, 0.9), hue(e * 0.05 + 0.25, 0.9), hue(0.6 + sin(e) * 0.05, 0.8), hue(e * 0.05 + 0.5, 0.9)]
                GlowRegistry.push(colors: cols, intensity: 0.95)
                TouchBarGlow.shared.update(colors: [cols[3], cols[0], cols[2], cols[1]])
                let b = (0..<5).map { i in Float(0.5 + 0.45 * sin(e * (6 + Double(i) * 2.3))) }
                AudioBarsRegistry.push(b)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        simTimer = t
    }
}

/// Direct line to the glow layer, so 10 colour updates a second never re-render SwiftUI.
@MainActor
enum GlowRegistry {
    static weak var view: GlowEdge.GlowLayerView?
    static func push(colors: [NSColor], intensity: CGFloat, cut: Bool = false) {
        guard ChromeAmbilight.shared.engaged || ChromeAmbilight.shared.simulating else { return }
        view?.pushCinema(colors: colors, intensity: intensity, cut: cut)
    }
    static func refreshFromConfig() { view?.endCinema(); InteriorRegistry.clear() }
    static func thump() { view?.thump() }
}

/// Direct line to the pill's visualiser bars (no SwiftUI re-render per update).
@MainActor
enum AudioBarsRegistry {
    static weak var view: AudioBars.BarsView?
    static func push(_ levels: [Float]) { view?.setLevels(levels) }
    static func idle() { view?.setLevels(nil) }
}


/// Lit from inside: a soft left-to-right gradient of the scene inside the black pill.
@MainActor
enum InteriorRegistry {
    static weak var view: InteriorLight.LightView?
    static func push(left: NSColor, right: NSColor, brightness: Double) {
        view?.set(left: left, right: right, alpha: Float(0.12 + 0.12 * min(brightness * 1.4, 1)))
    }
    static func clear() { view?.set(left: .black, right: .black, alpha: 0) }
}

struct InteriorLight: NSViewRepresentable {
    func makeNSView(context: Context) -> LightView { LightView() }
    func updateNSView(_ v: LightView, context: Context) {}
    final class LightView: NSView {
        private let g1 = CAGradientLayer(), g2 = CAGradientLayer()
        private var showing1 = true
        private let host = CALayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for g in [g1, g2] {
                g.startPoint = CGPoint(x: 0, y: 0.5); g.endPoint = CGPoint(x: 1, y: 0.5)
                g.colors = [NSColor.black.cgColor, NSColor.black.cgColor]
                g.locations = [0, 0.5, 1]
                g.opacity = 0
                host.addSublayer(g)
            }
            host.opacity = 0
            layer?.addSublayer(host)
            MainActor.assumeIsolated { InteriorRegistry.view = self }
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            host.frame = bounds; g1.frame = bounds; g2.frame = bounds
            CATransaction.commit()
        }
        func set(left: NSColor, right: NSColor, alpha: Float) {
            let d = MainActor.assumeIsolated { Power.shared.colourInterval }
            let cols = [left.cgColor, NSColor.black.cgColor, right.cgColor]
            CAQuiet.crossfade(g1, g2, showingA: &showing1, set: { ($0 as? CAGradientLayer)?.colors = cols }, duration: d)
            CAQuiet.animate(host, "opacity", to: alpha, duration: d)
        }
    }
}

/// Full-width sound wave: a faint spectrum across the whole pill, behind the content.
@MainActor
enum WaveRegistry {
    static weak var view: SoundWave.WaveView?
    static func push(_ b: [Float]) { view?.set(b) }
}

struct SoundWave: NSViewRepresentable {
    func makeNSView(context: Context) -> WaveView { WaveView() }
    func updateNSView(_ v: WaveView, context: Context) {}
    final class WaveView: NSView {
        private var bars: [CALayer] = []
        private let count = 36
        private var levels: [Float] = Array(repeating: 0, count: 36)
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for _ in 0..<count {
                let l = CALayer()
                l.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
                l.cornerRadius = 1
                layer?.addSublayer(l)
                bars.append(l)
            }
            MainActor.assumeIsolated { WaveRegistry.view = self }
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() { super.layout(); apply(animated: false) }
        func set(_ b: [Float]) {
            // The 4 bands spread across the width: bass in the centre, treble at the edges.
            let phase = Float(Date().timeIntervalSinceReferenceDate * 6)
            for i in 0..<count {
                let f = Float(i) / Float(count - 1)
                let m = abs(f - 0.5) * 2
                let pos = (1 - m) * 3
                let lo = Int(pos), hi = min(lo + 1, 3), w = pos - Float(lo)
                let v = b[lo] * (1 - w) + b[hi] * w
                let tex = 0.8 + 0.2 * sin(Float(i) * 1.7 + phase)
                levels[i] = max(0.04, min(1, v * tex))
            }
            apply(animated: true)
        }
        private func apply(animated: Bool) {
            CATransaction.begin()
            if animated { CATransaction.setAnimationDuration(0.07) } else { CATransaction.setDisableActions(true) }
            let w = bounds.width / CGFloat(count)
            for (i, l) in bars.enumerated() {
                let h = max(1, bounds.height * 0.7 * CGFloat(levels[i]))
                l.frame = CGRect(x: CGFloat(i) * w + w * 0.3, y: (bounds.height - h) / 2, width: max(1, w * 0.4), height: h)
            }
            CATransaction.commit()
        }
    }
}

// MARK: - Full-width equaliser inside the pill (replaces the faint wave + right-hand bars)

@MainActor
enum EqualiserRegistry {
    static weak var view: Equaliser.EQView?
    nonisolated(unsafe) static var appliedTimes: [Date] = []
    static var appliedRate: Double { Double(appliedTimes.filter { Date().timeIntervalSince($0) < 5 }.count) / 5 }
    static func push(_ levels: [Float], interval: Double = 1.0 / 12) {
        guard let view else { return }
        appliedTimes.append(Date()); if appliedTimes.count > 64 { appliedTimes.removeFirst(appliedTimes.count - 64) }
        view.setLevels(levels, interval: interval)
    }
    /// Old extension (4 bands only): spread them across all bars.
    static func push4(_ b: [Float]) {
        let n = Equaliser.count
        let lv = (0..<n).map { i -> Float in
            let pos = Float(i) / Float(n - 1) * 3
            let lo = Int(pos), hi = min(lo + 1, 3), w = pos - Float(lo)
            let tex = 0.85 + 0.15 * sin(Float(i) * 2.1)
            return (b[lo] * (1 - w) + b[hi] * w) * tex
        }
        view?.setLevels(lv)
    }
    /// Scene colours, lifted so the bars always read bright on the black pill (a dark scene
    /// dims the glow, never the equaliser).
    static func colours(_ c: [NSColor]) {
        let bright = c.map { col -> NSColor in
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            (col.usingColorSpace(.sRGB) ?? col).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return NSColor(hue: h, saturation: min(s, 0.85), brightness: max(b, 0.92), alpha: 1)
        }
        view?.setColours(bright, duration: Power.shared.colourInterval)
    }
    static func thump() { view?.thump() }
    static func flat() { view?.setMode(.flat) }
    static func idle() { view?.setMode(.idle) }
}

/// Low-cost animation helper: the app sets a target once per interval and the render server
/// interpolates at a capped frame rate, so the app process sleeps between updates.
enum CAQuiet {
    static let rate = CAFrameRateRange(minimum: 10, maximum: 24, preferred: 20)

    /// Crossfade between two pre-coloured layers: the new colours are drawn ONCE into the
    /// hidden layer, then only opacity animates (pure GPU compositing, nothing re-rendered).
    static func crossfade(_ a: CALayer, _ b: CALayer, showingA: inout Bool, set: (CALayer) -> Void, duration: CFTimeInterval) {
        let incoming = showingA ? b : a, outgoing = showingA ? a : b
        CATransaction.begin(); CATransaction.setDisableActions(true)
        set(incoming)
        CATransaction.commit()
        animate(incoming, "opacity", to: Float(1), duration: duration)
        animate(outgoing, "opacity", to: Float(0), duration: duration)
        showingA.toggle()
    }
    static func animate(_ layer: CALayer, _ key: String, to value: Any, duration: CFTimeInterval) {
        let from = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        CATransaction.commit()
        guard duration > 0 else { return }
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = value
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        a.preferredFrameRateRange = rate
        layer.add(a, forKey: key)
    }
}

struct Equaliser: NSViewRepresentable {
    static let count = 28
    func makeNSView(context: Context) -> EQView { EQView() }
    func updateNSView(_ v: EQView, context: Context) {}

    /// One long version of the pill's right-hand bars: the same bar width (2.5 pt), spacing,
    /// round caps and solid bright colour, repeated across the pill. The 28 analyser bands are
    /// interpolated onto however many bars fit. Only bar heights and colours animate (render
    /// server, up to 60 fps between ~24 targets a second); nothing is redrawn.
    final class EQView: NSView {
        enum Mode { case live, flat, idle }
        static let barWidth: CGFloat = 3, gap: CGFloat = 3          // as AudioBars: rounded, clean gaps
        private var bars: [CALayer] = []
        private var levels = [Float](repeating: 0.05, count: Equaliser.count)   // per band
        private var shown: [Float] = []                                          // per bar
        private var colours: [NSColor] = []
        private var mode: Mode = .idle
        private var lastColourKey = ""
        private var fullH: CGFloat = 14
        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            setColours(MainActor.assumeIsolated { Self.fallbackColours() }, duration: 0)
            MainActor.assumeIsolated { EqualiserRegistry.view = self }
        }
        required init?(coder: NSCoder) { fatalError() }

        @MainActor static func fallbackColours() -> [NSColor] {
            let p = Look.shared.musicPalette
            return [p[0], p.count > 1 ? p[1] : p[0], p[0]]
        }

        override func layout() {
            super.layout()
            let w = Self.barWidth, gap = Self.gap
            let n = max(4, Int((bounds.width + gap) / (w + gap)))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if n != bars.count {
                bars.forEach { $0.removeFromSuperlayer() }
                bars = (0..<n).map { _ in
                    let l = CALayer()
                    l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                    l.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
                    layer?.addSublayer(l)
                    return l
                }
                shown = [Float](repeating: -1, count: n)
                lastColourKey = ""
                setColours(colours, duration: 0)
            }
            fullH = max(4, min(bounds.height - 2, 22))   // headroom for the loudest beats (resting dots unchanged)
            let used = CGFloat(n) * w + CGFloat(n - 1) * gap
            let x0 = (bounds.width - used) / 2
            for (i, l) in bars.enumerated() {
                l.bounds = CGRect(x: 0, y: 0, width: w, height: max(w, fullH * CGFloat(max(0.12, shown[i]))))
                l.position = CGPoint(x: (x0 + CGFloat(i) * (w + gap) + w / 2).rounded() + 0.25, y: bounds.midY)
                l.cornerRadius = w / 2
            }
            CATransaction.commit()
            if mode == .idle { setMode(.idle) } else { apply(duration: 0, force: true) }
        }

        func setColours(_ c: [NSColor], duration: CFTimeInterval = 0.2) {
            guard !c.isEmpty else { return }
            let key = c.map { $0.description }.joined()
            guard key != lastColourKey else { return }
            lastColourKey = key
            colours = c
            let n = max(1, bars.count - 1)
            for (i, l) in bars.enumerated() {
                CAQuiet.animate(l, "backgroundColor", to: colourAt(Double(i) / Double(n)).cgColor, duration: duration)
            }
        }

        private func colourAt(_ x: Double) -> NSColor {
            guard colours.count > 1 else { return colours.first ?? .white }
            let pos = x * Double(colours.count - 1)
            let i = min(Int(pos), colours.count - 2)
            let f = CGFloat(pos - Double(i))
            return colours[i].usingColorSpace(.sRGB)!.blended(withFraction: f, of: colours[i + 1].usingColorSpace(.sRGB)!) ?? colours[i]
        }

        func setLevels(_ lv: [Float], interval: CFTimeInterval = 1.0 / 24) {
            if mode != .live { mode = .live; bars.forEach { $0.removeAnimation(forKey: "idle") } }
            let n = min(lv.count, levels.count)
            for i in 0..<n {
                // Light spatial smoothing (0.25 / 0.5 / 0.25) so the shape flows across bands.
                let l = lv[max(0, i - 1)], c = lv[i], r = lv[min(n - 1, i + 1)]
                levels[i] = max(0, min(1, 0.25 * l + 0.5 * c + 0.25 * r))
            }
            apply(duration: interval * 1.15, force: false)   // tween slightly past the next target: no stalls
        }

        func setMode(_ m: Mode) {
            guard m != .live else { return }
            mode = m
            for i in 0..<levels.count { levels[i] = m == .flat ? 0.04 : 0.3 }
            apply(duration: 0.3, force: true)
            for (i, l) in bars.enumerated() {
                l.removeAnimation(forKey: "idle")
                guard m == .idle else { continue }
                let a = CABasicAnimation(keyPath: "bounds.size.height")
                // A gentle travelling wave (only when the site gives no audio data).
                a.fromValue = max(Self.barWidth, fullH * 0.2); a.toValue = fullH * 0.55; a.duration = 1.1
                a.autoreverses = true; a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.beginTime = CACurrentMediaTime() + Double(i) * 0.035
                a.preferredFrameRateRange = CAQuiet.rate
                l.add(a, forKey: "idle")
            }
        }

        func thump() {
            for l in bars.prefix(bars.count / 5) {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1; a.toValue = 0.8; a.duration = 0.25
                a.preferredFrameRateRange = CAQuiet.rate
                l.add(a, forKey: "thump")
            }
        }

        private static let smoothRate = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)

        /// Band level at a bar position (0 = bass on the left, 1 = treble on the right).
        private func level(at x: Double) -> Float {
            let pos = x * Double(levels.count - 1)
            let i = min(Int(pos), levels.count - 2), f = Float(pos - Double(i))
            return levels[i] * (1 - f) + levels[i + 1] * f
        }

        private func apply(duration: CFTimeInterval, force: Bool) {
            let n = max(1, bars.count - 1)
            for (i, l) in bars.enumerated() {
                let v = 0.12 + 0.88 * level(at: Double(i) / Double(n))   // silence rests on a thin baseline
                // Skip bars that barely moved: no animation, no render-server work.
                if !force && abs(v - shown[i]) < 0.015 { continue }
                shown[i] = v
                let h = max(Self.barWidth, fullH * CGFloat(v))
                let from = (l.presentation() ?? l).bounds.size.height
                CATransaction.begin(); CATransaction.setDisableActions(true)
                l.bounds.size.height = h
                CATransaction.commit()
                guard duration > 0 else { l.removeAnimation(forKey: "h"); continue }
                let a = CABasicAnimation(keyPath: "bounds.size.height")
                a.fromValue = from; a.toValue = h; a.duration = duration
                a.timingFunction = CAMediaTimingFunction(name: .linear)   // curves come from the analyser
                a.preferredFrameRateRange = Self.smoothRate                // render server tweens at up to 60 fps
                l.add(a, forKey: "h")
            }
        }
    }
}
