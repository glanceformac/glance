import AppKit
import SwiftUI
import Accelerate

// MARK: feat/prompter: debug commands (only with --debug) and a simulated voice source for tests.

@MainActor
enum PrompterDebug {
    static let demoText = """
    Good morning everyone, and thank you for joining today's review.
    We have three things to cover: the shift handover tool, the pilot results, and next steps.

    First, the handover tool. Nurses told us that the morning handover takes far too long, and important details get lost between shifts.
    So we built a simple summary that is ready before the shift starts.

    Second, the pilot results. Over four weeks, handover time dropped and fewer tasks were missed.
    Ward managers said the summary was clear, and the night team asked to keep using it.

    Finally, next steps. We would like to extend the pilot to two more wards this winter.
    Thank you for listening. I am happy to take any questions now.
    """

    static func write(_ name: String, _ text: String) {
        let dir = DebugChannel.snapshotDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Returns true when the command was a Prompter one.
    static func run(_ cmd: String) -> Bool {
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let pr = Prompter.shared
        switch parts.first ?? "" {
        case "prompter-demo":
            // prompter-demo[:<countdown seconds>] (isolated test instances only)
            guard Env.isolated else { return true }
            var p = AppSettings.shared.prefs
            p.prompterCountdown = PrompterCountdown(rawValue: Int(arg) ?? 0) ?? .off
            AppSettings.shared.prefs = p
            pr.start(PrompterScript(title: "Demo", text: demoText))
        case "prompter-long":
            // prompter-long:<words> a long script, for memory / CPU checks
            guard Env.isolated else { return true }
            let n = Int(arg) ?? 3000
            let base = ScriptMatcher.tokens(demoText.replacingOccurrences(of: "\n", with: " "))
            var out: [String] = []
            for i in 0..<n { out.append(base[i % base.count]); if i % 120 == 119 { out.append("\n") } }
            pr.start(PrompterScript(title: "Long", text: out.joined(separator: " ")))
        case "prompter-set":
            // prompter-set:<field>=<value> (in memory in test mode)
            guard Env.isolated else { return true }
            let kv = arg.split(separator: "=", maxSplits: 1).map(String.init); guard kv.count == 2 else { return true }
            var p = AppSettings.shared.prefs
            switch kv[0] {
            case "speed": p.prompterSpeed = PrompterSpeed(rawValue: kv[1]) ?? p.prompterSpeed
            case "countdown": p.prompterCountdown = PrompterCountdown(rawValue: Int(kv[1]) ?? 0) ?? .off
            case "size": p.prompterSize = PrompterSize(rawValue: kv[1]) ?? p.prompterSize
            case "colour": p.prompterColour = kv[1]
            case "width": p.prompterWidth = Double(kv[1]) ?? p.prompterWidth
            case "height": p.prompterHeight = Double(kv[1]) ?? p.prompterHeight
            case "mirror": p.prompterMirror = kv[1] == "true"
            case "hide": p.prompterHideFromSharing = kv[1] == "true"
            case "voice": p.prompterVoice = PrompterVoice(rawValue: kv[1]) ?? .off
            default: break
            }
            AppSettings.shared.prefs = p
            pr.restyle()
            pr.go()
        case "prompter-stop": pr.stop()
        case "prompter-pause": pr.togglePause()
        case "prompter-hover": pr.setHover(arg == "on")
        case "prompter-nudge": pr.nudge(CGFloat(Double(arg) ?? 60))
        case "prompter-key":
            // prompter-key:<keyCode> sends a key to the prompter window (53 Esc, 49 Space, 125 Down)
            guard let w = NSApp.windows.first(where: { $0 is PrompterPanel }), let code = UInt16(arg),
                  let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
            else { return true }
            w.sendEvent(e)
        case "prompter-click":
            // A real mouse-down event at the centre of the box (goes through the view's mouseDown).
            guard let w = NSApp.windows.first(where: { $0 is PrompterPanel }), let v = w.contentView,
                  let e = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: v.bounds.midX, y: v.bounds.midY), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { return true }
            w.sendEvent(e)
        case "prompter-scroll":
            // prompter-scroll:<lines> a real scroll-wheel event over the box (wheel units)
            guard let w = NSApp.windows.first(where: { $0 is PrompterPanel }), let v = w.contentView,
                  let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(Int(arg) ?? -2), wheel2: 0, wheel3: 0)
            else { return true }
            cg.location = CGPoint(x: w.frame.midX, y: (NSScreen.screens.first?.frame.maxY ?? 900) - w.frame.midY)
            if let e = NSEvent(cgEvent: cg), let hit = v.hitTest(NSPoint(x: v.bounds.midX, y: v.bounds.midY)) { hit.scrollWheel(with: e) }
        case "prompter-hear":
            // prompter-hear:<words> simulated recognised words (the whole utterance so far)
            let words = arg.split(separator: " ").map(String.init)
            if !pr.smartActive { pr.setSmartActive(true, status: "Following your words (simulated)") }
            pr.heard(words) { moved in
                let li = pr.lastFollowTarget.map { pr.line(atOffset: $0) } ?? -1
                write("prompter-match.txt", "moved=\(moved.map(String.init) ?? "nil") word=\(pr.lastMatchedWord) line=\(li) text=\(li >= 0 ? pr.lines[li].text : "-")\n")
            }
        case "prompter-sim":
            // prompter-sim:basic|smart|off  simulated microphone (and recogniser for smart), no permissions
            pr.simulator?.stop(); pr.simulator = nil
            guard arg == "basic" || arg == "smart", pr.running else { if pr.smartActive { pr.setSmartActive(false, status: "") }; return true }
            let sim = PrompterVoiceSimulator(smart: arg == "smart", words: pr.lines.flatMap { $0.text.split(separator: " ").map(String.init) })
            pr.simulator = sim
            pr.setSmartActive(arg == "smart", status: arg == "smart" ? "Following your words (simulated)" : "Scrolling while you speak (simulated)")
            sim.start()
        case "prompter-status":
            let sc = pr.scroller
            let w = NSApp.windows.first(where: { $0 is PrompterPanel })
            let island = NSApp.windows.first(where: { $0 is IslandPanel })
            let s = [
                "running=\(pr.running) paused=\(pr.paused) hoverPaused=\(pr.hoverPaused) countdown=\(pr.countdown)",
                "voice=\(pr.voiceMode.rawValue) effective=\(pr.effectiveVoice.rawValue) hearing=\(pr.hearing) smartActive=\(pr.smartActive) status=\(pr.voiceStatus)",
                "offset=\(String(format: "%.1f", sc?.currentOffset ?? -1)) moving=\(sc?.isMoving ?? false) line=\(pr.currentLine + 1)/\(pr.lines.count) progress=\(String(format: "%.3f", pr.progress)) matchedWord=\(pr.lastMatchedWord)",
                "speed=\(AppSettings.shared.prefs.prompterSpeed.rawValue) size=\(AppSettings.shared.prefs.prompterSize.rawValue) colour=\(AppSettings.shared.prefs.prompterColour) mirror=\(AppSettings.shared.prefs.prompterMirror)",
                "window=\(w.map { NSStringFromRect($0.frame) } ?? "none") level=\(w?.level.rawValue ?? -1) sharingType=\(w.map { $0.sharingType == .none ? "none" : "readOnly/readWrite(\($0.sharingType.rawValue))" } ?? "-") key=\(w?.isKeyWindow ?? false)",
                "screen=\(NSStringFromRect(NSScreen.screens.first?.frame ?? .zero)) islandWindow=\(island.map { NSStringFromRect($0.frame) } ?? "none") pillBottom=\((NSScreen.screens.first?.frame.maxY ?? 0) - IslandMetrics.closed.height)",
                "context=\(IslandContext.shared.current.rawValue) prompterAllowed=\(IslandContext.shared.prompterAllowed) cinemaAllowed=\(IslandContext.shared.cinemaAllowed) cinemaEngaged=\(ChromeAmbilight.shared.engaged) peekShowing=\(IslandModel.shared.peek?.title ?? "none") soundsAllowed=\(IslandContext.shared.soundsAllowed)",
                "scripts=\(PrompterLibrary.shared.scripts.count) [\(PrompterLibrary.shared.scripts.map(\.title).joined(separator: ", "))]",
            ]
            write("prompter-status.txt", s.joined(separator: "\n") + "\n")
        case "prompter-snap":
            // Render the prompter box at its current on-screen position (holds for the snapshot, then resumes).
            if let sc = pr.scroller, sc.isMoving { sc.hold(at: sc.currentOffset); DebugChannel.snapshot(name: "prompter-" + (arg.isEmpty ? "box" : arg)); pr.go() }
            else { DebugChannel.snapshot(name: "prompter-" + (arg.isEmpty ? "box" : arg)) }
        case "prompter-lib":
            // prompter-lib:add=<title>|paste|import=<path>|rename=<index>=<title>|delete=<index>|clear
            let lib = PrompterLibrary.shared
            let kv = arg.split(separator: "=", maxSplits: 2).map(String.init)
            switch kv.first ?? "" {
            case "add": lib.add(title: kv.count > 1 ? kv[1] : "", text: demoText)
            case "paste":
                // A private named pasteboard: the real clipboard is never read or changed.
                let pb = NSPasteboard(name: NSPasteboard.Name("app.glanceformac.glance.prompter.test"))
                pb.clearContents(); pb.setString(kv.count > 1 ? kv[1] : "Pasted line one\nPasted line two", forType: .string)
                lib.pasteNew(from: pb)
            case "edit": if kv.count > 1, let i = Int(kv[1]), lib.scripts.indices.contains(i) { lib.editRequest = lib.scripts[i].id }
            case "import": if kv.count > 1 { lib.importURL(URL(fileURLWithPath: kv[1])) }
            case "rename": if kv.count > 2, let i = Int(kv[1]), lib.scripts.indices.contains(i) { lib.rename(lib.scripts[i], to: kv[2]) }
            case "delete": if kv.count > 1, let i = Int(kv[1]), lib.scripts.indices.contains(i) { lib.delete(lib.scripts[i]) }
            case "start": if kv.count > 1, let i = Int(kv[1]), lib.scripts.indices.contains(i) { pr.start(lib.scripts[i]) }
            case "latest": pr.startLatest()
            default: break
            }
        case "prompter-page":
            IslandModel.shared.pinned = true
            withAnimation(IslandModel.openSpring) { IslandModel.shared.page = .prompter }
            IslandModel.shared.setExpanded(true)
        case "prompter-settings-snap":
            renderSettings()
        default: return false
        }
        return true
    }

    /// The Settings section rendered off-screen in-process (no screen capture).
    static func renderSettings() {
        let size = NSSize(width: 520, height: 760)
        let host = NSHostingView(rootView: Form { PrompterSettingsSection() }.formStyle(.grouped).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = DebugChannel.snapshotDir.appendingPathComponent("prompter-settings.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            _ = w
        }
    }
}

/// Stands in for the microphone and recogniser in tests: synthetic audio buffers at the real
/// tap rate (2048 frames at 48 kHz), RMS with vDSP, the same VoiceGate, and (smart) the script
/// read aloud as growing partial results at about 2.6 words a second with a pause every
/// sentence. Runs on a background queue like the real audio thread.
final class PrompterVoiceSimulator: @unchecked Sendable {
    private let smart: Bool
    private let words: [String]
    private let queue = DispatchQueue(label: "app.glanceformac.glance.prompter.sim", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var gate = VoiceGate()
    private var buffer = [Float](repeating: 0, count: 2048)
    private var t = 0.0, wordIndex = 0, nextWordAt = 0.6, pauseUntil = 0.0
    private var utterance: [String] = []
    private var lastPartial = 0.0

    init(smart: Bool, words: [String]) { self.smart = smart; self.words = words }

    func start() {
        let dt = 2048.0 / 48000.0
        let tm = DispatchSource.makeTimerSource(queue: queue)
        tm.schedule(deadline: .now() + dt, repeating: dt, leeway: .milliseconds(2))
        tm.setEventHandler { [weak self] in self?.step(dt) }
        timer = tm
        tm.resume()
    }

    private func step(_ dt: Double) {
        t += dt
        let talking = t >= pauseUntil && wordIndex < words.count
        // Speech: a 180 Hz tone with syllable-rate amplitude; silence: faint room noise.
        let amp: Float = talking ? 0.06 * Float(0.6 + 0.4 * abs(sin(t * 9))) : 0.002
        for i in 0..<buffer.count { buffer[i] = amp * sinf(Float(i) * 0.0236 + Float(t * 1131)) + Float.random(in: -0.001...0.001) }
        var rms: Float = 0
        vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(buffer.count))
        if let s = gate.feed(rms: rms, dt: dt) {
            DispatchQueue.main.async { MainActor.assumeIsolated { Prompter.shared.speaking(s) } }
        }
        guard talking, t >= nextWordAt else { return }
        let w = words[wordIndex]
        wordIndex += 1
        utterance.append(w)
        nextWordAt = t + 0.385
        if w.hasSuffix(".") || w.hasSuffix("?") { pauseUntil = t + 1.6; nextWordAt = pauseUntil + 0.2 }   // breath between sentences
        if smart, t - lastPartial >= 0.2 || w.hasSuffix(".") {
            lastPartial = t
            let u = utterance
            DispatchQueue.main.async { MainActor.assumeIsolated { Prompter.shared.heard(u) } }
            if utterance.count > 60 { utterance.removeFirst(30) }
        }
    }

    func stop() { timer?.cancel(); timer = nil }
}
