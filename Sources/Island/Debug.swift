import AppKit
import SwiftUI

/// Test channel, active ONLY when Glance is launched with `--debug`.
/// Lets a script drive states and save self-snapshots (an app may always capture
/// its own windows over the wallpaper without Screen Recording permission).
///   osascript/swift: post distributed notification "app.glanceformac.glance.debug" with object = command
@MainActor
enum DebugChannel {
    /// `GLANCE_DEBUG_TAG=<name>`: a private channel ("app.glanceformac.glance.debug.<name>") and its own
    /// snapshot folder, so several test instances (one per worktree) never answer each other.
    static let tag: String? = ProcessInfo.processInfo.environment["GLANCE_DEBUG_TAG"].flatMap { $0.isEmpty ? nil : $0 }

    static var snapshotDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Glance/debug", isDirectory: true)
        return tag.map { base.appendingPathComponent($0, isDirectory: true) } ?? base
    }

    static func install() {
        guard ProcessInfo.processInfo.arguments.contains("--debug") else { return }
        let name = "app.glanceformac.glance.debug" + (tag.map { "." + $0 } ?? "")
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { n in
            let cmd = (n.object as? String) ?? ""
            MainActor.assumeIsolated { run(cmd) }
        }
        NSLog("Glance debug channel active: %@", name)
    }

    static func run(_ cmd: String) {
        if CinemaProbe.run(cmd) { return }   // MARK: wip/cinema-h
        let m = IslandModel.shared
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first ?? "" {
        case "expand": m.pinned = true; m.setExpanded(true)
        case "open": m.pinned = false; m.setExpanded(true)   // like a hover, no pin
        case "collapse": m.pinned = false; m.setExpanded(false)
        case "edit": withAnimation { m.editing = true }
        case "page":
            let map: [String: ExpandedPage] = ["volume": .volume, "clipboard": .clipboard, "shelf": .shelf, "home": .widgets, "today": .today, "tools": .tools, "system": .system, "dev": .dev]
            withAnimation(IslandModel.openSpring) { m.page = map[parts.count > 1 ? parts[1] : "home"] ?? .widgets }
        case "hotkey": m.toggleClipboardFromHotkey()
        case "dragzone": withAnimation(IslandModel.openSpring) { m.page = .shelf; m.shelfDragActive = true }; m.setExpanded(true)
        case "dragend": m.shelfDragActive = false
        case "clip-demo": ClipboardStore.shared.debugDemo()
        case "clip-dump": ClipboardStore.shared.debugDump(to: snapshotDir.appendingPathComponent("clipboard-dump.json"))
        case "mic-sim":   // mic-sim:<bundle id>  -> that app "just finished recording" (dictation test)
            if parts.count > 1 { MicHistory.shared.simulated = (parts[1], Date()) }
        case "shelf-dump": ShelfStore.shared.debugDump(to: snapshotDir.appendingPathComponent("shelf-dump.json"))
        case "shelf-dragged":   // shelf-dragged:<index>  -> as if that tile was dropped somewhere
            let s = ShelfStore.shared
            if parts.count > 1, let i = Int(parts[1]), i < s.items.count { s.draggedOut(s.items[i]) }
        case "shelf-pin": if parts.count > 1, let i = Int(parts[1]), i < ShelfStore.shared.items.count { ShelfStore.shared.togglePin(ShelfStore.shared.items[i]) }
        case "shelf-undo": ShelfStore.shared.undoRemoval()
        case "update-check": Updater.shared.checkForUpdates()
        case "windows", "window-snap", "window-click":
            // Isolated test instances only: list / render / press a button in Glance's ordinary windows
            // (the Sparkle update window). Never the island panel, so never a Claude Allow button.
            guard Env.isolated else { break }
            let wins = NSApp.windows.filter { $0.isVisible && !($0 is IslandPanel) }
            let arg = parts.count > 1 ? parts[1] : ""
            if parts[0] == "windows" {
                let rows = wins.map { w in "\(w.title) | \(type(of: w)) | buttons: " + Self.buttons(in: w.contentView).map(\.title).joined(separator: ", ") }
                try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
                try? rows.joined(separator: "\n").write(to: snapshotDir.appendingPathComponent("windows.txt"), atomically: true, encoding: .utf8)
            } else if parts[0] == "window-snap" {
                if let w = wins.first, let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
                    try? rep.representation(using: .png, properties: [:])?.write(to: snapshotDir.appendingPathComponent("window-\(arg.isEmpty ? "1" : arg).png"))
                }
            } else if let b = wins.lazy.flatMap({ Self.buttons(in: $0.contentView) }).first(where: { $0.title == arg && $0.isEnabled }) {
                b.performClick(nil)
            }
        case "shelf-demo":
            let s = ShelfStore.shared
            // Only non-protected system files, so no privacy prompt is ever triggered.
            s.addFile(URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist"))
            s.addFile(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns"))
            s.addFile(URL(fileURLWithPath: "/System/Applications/Notes.app"))
            s.addLink(URL(string: "https://lrclib.net/docs")!)
            s.addText("Meeting notes: ship Glance v1 on Friday")
        case "peek": m.enqueue(Peek(symbol: "bolt.fill", title: "Charging", subtitle: "82%", tint: .green, duration: 6))
        case "peek-app":
            let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app")
            m.enqueue(Peek(icon: icon, title: "Opened", subtitle: "Notes", duration: 6))
        case "peek-done": m.enqueue(Peek(symbol: "checkmark.circle.fill", title: "Done", subtitle: "island  ·  2m 14s", tint: .green, duration: 6, prominent: true))
        case "theme-light": AppSettings.shared.prefs.theme = .whiteMatte
        case "theme-dark": AppSettings.shared.prefs.theme = .darkMatte
        #if DEBUG
        // Debug builds only: a release build can never be told to approve a command this way.
        case "allow": m.answerCurrent(allow: true)
        case "deny": m.answerCurrent(allow: false)
        #endif
        case "fake-media": NowPlaying.shared.debugFake()
        case "hide": if parts.count > 1, let c = CardKind(rawValue: parts[1]) { withAnimation(IslandModel.openSpring) { AppSettings.shared.hide(c) } }
        case "show": if parts.count > 1, let c = CardKind(rawValue: parts[1]) { withAnimation(IslandModel.openSpring) { AppSettings.shared.show(c) } }
        case "move": if parts.count > 1, let c = CardKind(rawValue: parts[1]) { withAnimation(IslandModel.openSpring) { AppSettings.shared.move(c, by: -1) } }
        case "glow": if parts.count > 1, let g = GlowStyle(rawValue: parts[1]) { AppSettings.shared.prefs.glowStyle = g }
        case "accent": if parts.count > 1, let a = AccentTheme(rawValue: parts[1]) { AppSettings.shared.prefs.accent = a }
        case "glowoff": AppSettings.shared.prefs.glowEnabled = false
        case "glowon": AppSettings.shared.prefs.glowEnabled = true
        case "celebrate":
            m.debugFixedTime = nil
            if parts.count > 1, let i = Int(parts[1]), i < CelebrationKind.previews.count { m.celebrate(CelebrationKind.previews[i].1) }
        case "frame":
            // frame:<previewIndex>:<seconds>  -> render a fixed frame of an animation (for snapshots).
            let bits = cmd.split(separator: ":")
            if bits.count == 3, let i = Int(bits[1]), let t = Double(bits[2]), i < CelebrationKind.previews.count {
                m.debugFixedTime = t
                if m.celebration?.kind != CelebrationKind.previews[i].1 { m.celebrate(CelebrationKind.previews[i].1) }
                if case .cinemaIntro = CelebrationKind.previews[i].1 { GlowRegistry.view?.freezeIntro(at: t) }
            }
        case "seq":
            // seq:open | seq:close  -> snapshots every ~16 ms for 0.75 s during the spring.
            let open = parts.count > 1 && parts[1] == "open"
            var n = 0
            let start = Date()
            let t = Timer(timeInterval: 0.016, repeats: true) { timer in
                MainActor.assumeIsolated {
                    snapshot(name: String(format: "seq-%@-%02d-%03dms", open ? "open" : "close", n, Int(Date().timeIntervalSince(start) * 1000)))
                    n += 1
                    if Date().timeIntervalSince(start) > 0.75 { timer.invalidate() }
                }
            }
            RunLoop.main.add(t, forMode: .common)
            if open { m.pinned = true; m.setExpanded(true) } else { m.pinned = false; m.setExpanded(false) }
        case "endceleb": m.debugFixedTime = nil; m.endCelebration()
        case "oppgoal": m.shakePill()
        case "live-demo":
            var lm = MatchInfo(id: "demo", league: "eng.1", leagueName: "Demo League", date: Date(), home: .demoHome, away: .demoAway,
                               homeScore: 1, awayScore: 0, state: "in", statusName: "STATUS_SECOND_HALF", clock: "67'", myTeamID: TeamInfo.demoHome.id)
            lm.clock = "67'"
            FootballService.shared.live = lm
        case "live-end": FootballService.shared.live = nil
        case "cinema-status": ChromeAmbilight.shared.writeStatus()
        case "pref":
            // pref:<name>=<true|false>  (isolated test instances only; nothing is saved)
            guard Env.isolated, parts.count > 1 else { break }
            let kv = parts[1].split(separator: "="); guard kv.count == 2 else { break }
            let on = kv[1] == "true"
            var p = AppSettings.shared.prefs
            switch kv[0] {
            case "cinemaWave": p.cinemaWave = on
            case "cinemaInterior": p.cinemaInterior = on
            case "glowEnabled": p.glowEnabled = on
            case "glowWhenClosed": p.glowWhenClosed = on
            case "cinemaProgress": p.cinemaProgress = on
            case "touchBarGlow": p.touchBarGlow = on
            case "shelfRemoveAfterDrag": p.shelfRemoveAfterDrag = on
            case "clipboardIgnore": p.clipboardIgnoredApps = kv[1].split(separator: ",").map(String.init)   // pref:clipboardIgnore=a,b
            default: break
            }
            AppSettings.shared.prefs = p
        case "cinema-fake":
            // cinema-fake:playing|paused  -> inject a simulated extension message (no Chrome involved)
            let st = parts.count > 1 ? parts[1] : "playing"
            ChromeAmbilight.shared.receive(["type": "frame", "state": st, "method": "direct", "audio": "ok", "domain": "example.com",
                                            "title": "Big Buck Bunny", "time": 312.0, "duration": 596.0, "rate": 1.0, "live": false,
                                            "colors": [[220.0, 60.0, 30.0], [40.0, 90.0, 220.0], [250.0, 170.0, 20.0], [200.0, 60.0, 120.0], [240.0, 140.0, 40.0]],
                                            "bands": [0.8, 0.6, 0.5, 0.3],
                                            "spectrum": (0..<28).map { i in 0.25 + 0.7 * abs(sin(Double(i) * 0.45 + Date().timeIntervalSinceReferenceDate * 3)) }])
        case "hovercontrols": m.hoverControls = parts.count > 1 && parts[1] == "on"
        case "showends": ChromeAmbilight.shared.showEnds()
        case "titlecard": ChromeAmbilight.shared.showTitleCard(after: 0)
        case "cinema-sim": ChromeAmbilight.shared.previewSimulated(seconds: 6)
        case "settings": AppDelegate.shared?.showSettings(page: parts.count > 1 ? SettingsPage(rawValue: parts[1]) : nil)   // settings[:<page>]
        case "settings-close": AppDelegate.shared?.closeSettings()
        case "tools": ToolsDebug.run(parts.count > 1 ? parts[1] : "")   // MARK: feat/productivity
        case "snapshot": snapshot(name: parts.count > 1 ? parts[1] : "snap")
        case "char": // MARK: wip/character  char:<state> plays a state for 60 s, char:live ends it
            CharacterEngine.shared.preview(parts.count > 1 ? CharacterState(rawValue: parts[1]) : nil, seconds: 60)
        case "char-rig-snap": // char-rig-snap:<state> one rig, stills, rendered offscreen at 2x
            let st = CharacterState(rawValue: parts.count > 1 ? parts[1] : "idle") ?? .idle
            // Live shadow clones: the strip is drawn to the right of the rig (stills).
            let pack = CharacterEngine.shared.pack ?? MochiArt.pack
            let helpers = CharacterEngine.shared.frame.helpers
            if let img = CharacterRigView.snapshot(st, pack: pack, clones: helpers) {
                try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: snapshotDir.appendingPathComponent("char-rig-\(st.rawValue)\(helpers.isEmpty ? "" : "-x\(helpers.count)").png"))
            }
        case "char-tb-snap": // the character Touch Bar strip, rendered offscreen
            let v = CharacterStripView(frame: NSRect(x: 0, y: 0, width: 1085, height: 30))
            v.apply(CharacterTouchBar.content())
            v.layoutSubtreeIfNeeded()
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
                try? rep.representation(using: .png, properties: [:])?.write(to: snapshotDir.appendingPathComponent("char-tb-\(CharacterEngine.shared.frame.state.rawValue).png"))
            }
        case "tb-snap":
            // tb-snap:<phase>  -> render the Touch Bar equaliser offscreen with a synthetic spectrum (no real Touch Bar).
            let ph = Double(parts.count > 1 ? parts[1] : "0") ?? 0
            let v = GlowStripView(frame: NSRect(x: 0, y: 0, width: 1004, height: 30))
            v.layout()
            v.setBarColours([NSColor(srgbRed: 0.9, green: 0.2, blue: 0.5, alpha: 1), NSColor(srgbRed: 1, green: 0.6, blue: 0.1, alpha: 1),
                             NSColor(srgbRed: 0.2, green: 0.8, blue: 0.9, alpha: 1), NSColor(srgbRed: 0.5, green: 0.3, blue: 1, alpha: 1)])
            let spec: [Float] = (0..<28).map { i in Float(max(0, ph == 0 ? 0 : (i < 6 ? 0.95 : 0.15 + 0.6 * abs(sin(Double(i) * 0.7 + ph))))) }
            v.setLevels(spec, duration: 0)
            guard let layer = v.layer, let ctx = CGContext(data: nil, width: 2008, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { break }
            ctx.scaleBy(x: 2, y: 2)
            layer.render(in: ctx)
            if let img = ctx.makeImage() {
                try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: snapshotDir.appendingPathComponent("tb-\(parts.count > 1 ? parts[1] : "0").png"))
            }
        default: if !PrompterDebug.run(cmd) && !DevFeatures.debug(cmd) { ControlsDebug.run(cmd); SystemMediaDebug.run(cmd) }   // MARK: feat/prompter, feat/claude-dev, feat/controls, feat/system-media
        }
    }

    static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        var out: [NSButton] = []
        if let b = view as? NSButton { out.append(b) }
        for sub in view.subviews { out += buttons(in: sub) }
        return out
    }

    /// Renders Glance's own windows to PNG (in-process layer rendering, no screen-capture
    /// API, so it never involves Screen Recording). Background is not included.
    static func snapshot(name: String) {
        let windows = NSApp.windows.filter { $0.isVisible && ($0 is IslandPanel || name.hasPrefix("full") || name.hasPrefix("prompter")) }
        let pick = name.hasPrefix("prompter") ? windows.first(where: { $0.contentView is NSHostingView<PrompterView> }) : (windows.first(where: { $0 is IslandPanel }) ?? windows.first)
        guard let w = pick,
              let view = w.contentView, let layer = view.layer else { return }
        let scale = w.backingScaleFactor
        let size = view.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // Neutral backdrop so the dark island is visible in the file.
        ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        ctx.scaleBy(x: scale, y: scale)
        if view.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
        // Presentation tree: shows Core Animation in flight (or frozen frames such as the intro).
        (layer.presentation() ?? layer).render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let dir = snapshotDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Encode off the main thread so sequences don't disturb the animation.
        DispatchQueue.global(qos: .utility).async {
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}

extension NowPlaying {
    /// Debug only: pretend a well-known song is playing to exercise UI + LRCLIB.
    func debugFake() {
        title = "Yellow"
        artist = "Coldplay"
        album = "Parachutes"
        duration = 269
        elapsedAtStamp = 62
        stamp = Date()
        isPlaying = true
        bundleID = "com.apple.Music"
        let img = NSImage(size: NSSize(width: 160, height: 160))
        img.lockFocus()
        NSGradient(colors: [NSColor.systemYellow, NSColor.systemOrange, NSColor(calibratedRed: 0.2, green: 0.1, blue: 0.3, alpha: 1)])!
            .draw(in: NSRect(x: 0, y: 0, width: 160, height: 160), angle: -60)
        img.unlockFocus()
        artwork = img
        Lyrics.shared.trackChanged()
    }
}

extension ClipboardStore {
    /// Debug only: demo rows without touching the real pasteboard.
    func debugDemo() {
        addSnippet(title: "Home address", text: "221B Baker Street, London NW1 6XE")
        addSnippet(title: "", text: "Kind regards,\nSam")
        debugInsert(ClipItem(kind: .link, text: "https://code.claude.com/docs/en/hooks", sourceApp: "Safari"))
        debugInsert(ClipItem(kind: .text, text: "swift build -c release && ./build.sh", sourceApp: "Ghostty"))
        debugInsert(ClipItem(kind: .files, paths: ["/System/Library/CoreServices/SystemVersion.plist"], sourceApp: "Finder"))
        debugInsert(ClipItem(kind: .text, text: "The quick brown fox jumps over the lazy dog, and then keeps running far past the edge of this row", sourceApp: "Notes"))
    }
}

extension ClipboardStore {
    /// Debug only: what history holds now (kind, source, first characters).
    func debugDump(to url: URL) {
        let rows = history.map { ["kind": $0.kind.rawValue, "source": $0.sourceApp ?? "", "bundle": $0.sourceBundle ?? "", "text": String(($0.text ?? $0.preview).prefix(60))] }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]).write(to: url)
    }
}

extension ShelfStore {
    /// Debug only: Shelf items (name, pinned) and the pending Undo.
    func debugDump(to url: URL) {
        let rows: [String: Any] = ["items": items.map { ["name": $0.name, "pinned": $0.pinned, "kind": $0.kind.rawValue] },
                                   "pendingUndo": pendingUndo?.name ?? ""]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]).write(to: url)
    }
}
