import AppKit
import SwiftUI
import AVFoundation

/// Test commands for the system-media features. Reached from the debug channel or, for isolated test
/// instances, from the instance's own socket (`{"hook_event_name":"IslandDebug","cmd":"..."}`).
/// Results are written as text files next to the snapshots.
@MainActor
enum SystemMediaDebug {
    static func out(_ name: String, _ text: String) {
        let dir = DebugChannel.snapshotDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }

    static func run(_ cmd: String) {
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let m = IslandModel.shared
        switch parts.first ?? "" {
        // MARK: shared
        case "snap": DebugChannel.snapshot(name: arg)
        case "syspage":
            if let t = SystemTab(rawValue: arg) { SystemPageState.shared.tab = t }
            m.pinned = true
            withAnimation(IslandModel.openSpring) { m.page = .system }
            m.setExpanded(true)
        case "soundpage":
            m.pinned = true
            withAnimation(IslandModel.openSpring) { m.page = .volume }
            m.setExpanded(true)
        case "shelfpage":
            m.pinned = true
            withAnimation(IslandModel.openSpring) { m.page = .shelf }
            m.setExpanded(true)
        case "clippage":
            m.pinned = true
            withAnimation(IslandModel.openSpring) { m.page = .clipboard }
            m.setExpanded(true)
        case "close": m.pinned = false; m.setExpanded(false)
        case "snapsettings":
            // Renders the Settings form in an off-screen window (never shown, never activates the app).
            let w = NSWindow(contentRect: NSRect(x: -30000, y: 100, width: 460, height: 1500), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: SettingsView().frame(width: 460, height: 1500))
            w.orderBack(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    guard let v = w.contentView, let layer = v.layer else { return }
                    let size = v.bounds.size
                    guard let ctx = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                    ctx.setFillColor(NSColor.windowBackgroundColor.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
                    ctx.scaleBy(x: 2, y: 2)
                    layer.render(in: ctx)
                    if let img = ctx.makeImage() {
                        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: DebugChannel.snapshotDir.appendingPathComponent("\(arg.isEmpty ? "settings" : arg).png"))
                    }
                    w.orderOut(nil)
                }
            }
        case "setpref":
            // setpref:name=true|false (isolated instances: in memory only)
            let kv = arg.split(separator: "=").map(String.init)
            guard Env.isolated, kv.count == 2 else { break }
            var p = AppSettings.shared.prefs
            let on = kv[1] == "true"
            switch kv[0] {
            case "liveActivities": p.liveActivities = on
            case "cameraGuard": p.cameraGuard = on
            case "cameraGuardMic": p.cameraGuardMic = on
            case "btConnectPeek": p.btConnectPeek = on
            case "capsLockHUD": p.capsLockHUD = on
            case "hudReplace": p.hudReplace = on
            case "screenshotShelf": p.screenshotShelf = on
            case "screenshotOCR": p.screenshotOCR = on
            case "screenshotPeek": p.screenshotPeek = on
            case "clipExtras": p.clipExtras = on
            case "snapZones": p.snapZones = on
            case "systemMonitor": p.systemMonitor = on
            case "activityRings": p.activityRings = on
            case "stocksEnabled": p.stocksEnabled = on
            case "deskPet": p.deskPet = on
            case "footballLivePill": p.footballLivePill = on
            default: break
            }
            AppSettings.shared.prefs = p

        // MARK: 1 Live Activities
        case "act-demo":
            ActivityCenter.start(id: "demo.timer", symbol: "timer", text: "", tint: Color(nsColor: Look.shared.accentNS), endDate: Date().addingTimeInterval(14 * 60 + 32))
            ActivityCenter.start(id: "demo.awake", symbol: "cup.and.saucer.fill", text: "Awake", tint: .orange)
            ActivityCenter.start(id: "demo.match", symbol: "soccerball", text: "ARS 1-0 TOT", tint: Color(red: 1, green: 0.3, blue: 0.3))
            ActivityCenter.start(id: "demo.claude", symbol: "sparkle", text: "island", tint: Color(red: 0.85, green: 0.47, blue: 0.34), startDate: Date().addingTimeInterval(-95))
        case "act-add": ActivityCenter.start(id: "demo.cmd", symbol: "terminal", text: "npm test", tint: .green, startDate: Date())
        case "act-update": ActivityCenter.update(id: "demo.awake", text: "Awake 1h")
        case "act-end": ActivityCenter.end(id: arg.isEmpty ? "demo.awake" : arg)
        case "act-clear": ActivityCenter.shared.removeAll()
        case "act-info":
            let a = ActivityCenter.shared.activities
            out("act-info", "count=\(a.count) visible=\(ActivityCenter.shared.visible.count)\n" + a.map { "\($0.id) \($0.symbol) \($0.text)" }.joined(separator: "\n") + "\npillSize=\(m.size)")
        case "act-socket":
            // Simulate an external long command through the same code path as the socket.
            ActivityHub.handle(["id": "build", "action": "start", "text": "npm test", "symbol": "terminal", "tint": "green", "elapsed": true])
        case "act-socket-end": ActivityHub.handle(["id": "build", "action": "end"])
        case "claude-fake":
            ActivityHub.claudeStarted(session: "s1", project: "island")
        case "claude-fake-end": ActivityHub.claudeStopped(session: "s1")
        case "timer-start": FocusTimer.shared.startTimer()
        case "timer-stop": FocusTimer.shared.reset()
        case "media-on": NowPlaying.shared.debugFake()
        case "match-live":
            var lm = MatchInfo(id: "demo", league: "eng.1", leagueName: "Demo League", date: Date(), home: .demoHome, away: .demoAway,
                               homeScore: 1, awayScore: 0, state: "in", statusName: "STATUS_SECOND_HALF", clock: "67'", myTeamID: TeamInfo.demoHome.id)
            lm.clock = "67'"
            FootballService.shared.live = lm

        // MARK: 2 Camera guard
        case "cam-sim":      // cam-sim:on|off
            CameraGuard.shared.simulate(camera: arg == "on", mic: nil, cameraApp: "Zoom")
        case "mic-sim":
            CameraGuard.shared.simulate(camera: nil, mic: arg == "on", micApp: "Microsoft Teams")
        case "guard-real":
            let g = CameraGuard.shared
            g.simCamera = nil; g.simMic = nil
            g.evaluate()
            out("guard-real", """
                cameraDevices=\(CameraGuard.cameraDeviceCount())
                IslandContext.cameraInUse=\(IslandContext.shared.cameraInUse)
                audioProcessObjects=\(CameraGuard.audioProcesses().count)
                micClients(other than Glance)=\(CameraGuard.micClients().map { "\($0.pid):\($0.bundle ?? "?")" })
                state camera=\(g.cameraInUse) mic=\(g.micInUse) inUse=\(g.inUse)
                """)
        case "guard-state":
            let g = CameraGuard.shared
            out("guard-state", "camera=\(g.cameraInUse) app=\(g.cameraApp ?? "-") mic=\(g.micInUse) app=\(g.micApp ?? "-") peek=\(m.peek?.title ?? "-") sub=\(m.peek?.subtitle ?? "-")")

        // MARK: 3 Sound
        case "sound-info":
            let s = SoundCenter.shared
            s.refresh(announce: false)
            out("sound-info", """
                outputs: \(s.outputs.map { "\($0.name)\($0.id == s.defaultOutput ? " [default]" : "")\($0.bluetooth ? " [bt]" : "")" })
                inputs: \(s.inputs.map { "\($0.name)\($0.id == s.defaultInput ? " [default]" : "")\($0.bluetooth ? " [bt]" : "")" })
                volume=\(VolumeControl.shared.volume) muted=\(VolumeControl.shared.muted) available=\(VolumeControl.shared.available)
                """)
        case "sound-setsame":
            // Sets the default output to the device that is ALREADY the default: proves the setter path without changing anything.
            let s = SoundCenter.shared
            if let d = s.outputs.first(where: { $0.id == s.defaultOutput }) { s.setDefault(d, input: false); out("sound-setsame", "set default output to itself: \(d.name) now=\(SoundCenter.defaultDevice(input: false) == d.id)") }
            if let d = s.inputs.first(where: { $0.id == s.defaultInput }) { s.setDefault(d, input: true) }
        case "bt-peek": SoundCenter.shared.showConnectPeek(name: "Sam’s AirPods Pro", battery: "L 80  R 82  Case 90")
        case "bt-peek-nobattery": SoundCenter.shared.showConnectPeek(name: "JBL Flip 6", battery: nil)
        case "bt-parse":
            let json = """
            {"SPBluetoothDataType":[{"device_connected":[{"Sam’s AirPods Pro":{"device_batteryLevelCase":"90%","device_batteryLevelLeft":"80%","device_batteryLevelRight":"82%"}},{"Magic Mouse":{"device_batteryLevelMain":"64%"}},{"Speaker":{"device_address":"x"}}]}]}
            """.data(using: .utf8)!
            out("bt-parse", """
                airpods=\(SoundCenter.parseBattery(json: json, name: "Sam’s AirPods Pro") ?? "nil")
                mouse=\(SoundCenter.parseBattery(json: json, name: "Magic Mouse") ?? "nil")
                speaker(no battery)=\(SoundCenter.parseBattery(json: json, name: "Speaker") ?? "nil")
                """)
        case "bt-real":
            Task.detached {
                let t0 = Date()
                // Real system_profiler run: lists battery of any connected device whose name is given.
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler"); p.arguments = ["SPBluetoothDataType", "-json"]
                let pipe = Pipe(); p.standardOutput = pipe
                try? p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                let root = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
                let arr = (root["SPBluetoothDataType"] as? [[String: Any]]) ?? []
                let connected = arr.flatMap { ($0["device_connected"] as? [[String: Any]]) ?? [] }.flatMap { $0.keys }
                let secs = Date().timeIntervalSince(t0)
                await MainActor.run { out("bt-real", "system_profiler ok bytes=\(d.count) connectedDevices=\(Array(connected)) took=\(String(format: "%.2f", secs))s") }
            }
        case "caps-sim": SoundCenter.shared.capsLockChanged(arg == "on")
        case "hud-vol":
            VolumeControl.shared.setMuted(false)
            SoundCenter.shared.showHUD(symbol: "speaker.wave.2.fill", title: "Volume", value: Double(arg) ?? 0.6)
        case "hud-bri": SoundCenter.shared.showHUD(symbol: "sun.max.fill", title: "Brightness", value: Double(arg) ?? 0.7)

        // MARK: 4 Screenshots
        case "shots-info":
            let s = ScreenshotShelf.shared
            out("shots-info", """
                folder=\(s.folder?.path ?? "nil") readable=\(s.folderReadable)
                items=\(s.items.map(\.name))
                ocr=\(s.items.map { "\($0.name): \((s.text[$0.id] ?? "<none>").replacingOccurrences(of: "\n", with: " | ").prefix(80))" })
                indexing=\(s.indexing)
                """)
        case "shots-scan": ScreenshotShelf.shared.scan()

        // MARK: 5 Clipboard extras
        case "cliptest":
            var lines: [String] = []
            let urls = [
                "https://example.com/a?utm_source=x&utm_medium=y&id=5",
                "https://example.com/?fbclid=IwAR123",
                "https://example.com/p?gclid=abc&keep=1&UTM_Campaign=z",
                "https://example.com/plain?x=1",
                "not a url",
                "https://example.com/path#frag?utm_source=a",
                "https://example.com/?utm_source=a&utm_term=b",
            ]
            for u in urls { lines.append("strip \(u) -> \(ClipTools.stripTracking(u) ?? "nil (unchanged)")") }
            for c in ["#ff8800", "#f80", "#FF8800CC", "rgb(255, 136, 0)", "rgba(255,136,0,0.5)", "hsl(32, 100%, 50%)", "hello", "#12", "rgb(300,0,0)", "ace"] {
                lines.append("color \(c) -> \(ClipTools.color(from: c).map { ClipTools.hex($0) } ?? "nil")")
            }
            out("cliptest", lines.joined(separator: "\n"))
        case "clip-extras-demo":
            let s = ClipboardStore.shared
            s.debugInsert(ClipItem(kind: .text, text: "#FF6B35", sourceApp: "Figma"))
            s.debugInsert(ClipItem(kind: .text, text: "rgb(46, 134, 222)", sourceApp: "Safari"))
            s.debugInsert(ClipItem(kind: .link, text: "https://shop.example.com/item?id=42&utm_source=news&utm_medium=email&fbclid=IwAR0", sourceApp: "Mail"))
            s.debugInsert(ClipItem(kind: .text, text: "Plain words from a web page", sourceApp: "Safari"))
            s.debugInsert(ClipItem(kind: .text, text: "swift build -c release", sourceApp: "Ghostty"))
        case "quickpaste":
            // quickpaste:N -> pastes the Nth numbered clipboard item (copy only; no Accessibility in tests)
            let n = Int(arg) ?? 1
            let list = ClipQuickPaste.shared.numbered
            let ok = ClipQuickPaste.shared.paste(n)
            out("quickpaste", "n=\(n) ok=\(ok) numbered=\(list.map(\.displayTitle)) pasteboard=\(Env.pasteboard.string(forType: .string) ?? "nil")")
        case "airdrop-info":
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory() + "island-airdrop-test.txt")
            try? "hi".write(to: tmp, atomically: true, encoding: .utf8)
            out("airdrop-info", "service=\(AirDrop.service?.title ?? "nil") canPerform(file)=\(AirDrop.canSend([tmp])) canPerform(raw string)=\(AirDrop.canSend(["hello"])) canPerform(url)=\(AirDrop.canSend([URL(string: "https://example.com")!]))")
        // MARK: 6 Snap zones
        case "snap-show": SnapZones.shared.debugShow(SnapZone(rawValue: Int(arg) ?? 0))
        case "snap-hide": SnapZones.shared.deactivate()
        case "snap-geom":
            let s = SnapZones.shared
            let v = SafeScreen.primary.visibleFrame
            var t = "visible=\(v)\n"
            for z in SnapZone.allCases { t += "\(z.title): appkit=\(z.frame(in: v)) ax=\(s.axRect(z.frame(in: v)))\n" }
            for (z, r) in s.tileFrames() { t += "tile \(z.title): \(r) hit-centre=\(s.zone(at: CGPoint(x: r.midX, y: r.midY))?.title ?? "nil")\n" }
            t += "outside-hit=\(s.zone(at: CGPoint(x: 5, y: 5))?.title ?? "nil") trusted=\(s.trusted)"
            out("snap-geom", t)

        // MARK: 7 Monitor
        case "mon-info":
            let mon = SystemMonitor.shared
            out("mon-info", """
                sampling=\(mon.isSampling) samples=\(mon.samples)
                cpu=\(String(format: "%.1f", mon.cpu * 100))% mem=\(String(format: "%.2f", mon.memoryUsedGB))/\(String(format: "%.1f", mon.memoryTotalGB)) GB
                disk=\(String(format: "%.0f", mon.diskFreeGB))/\(String(format: "%.0f", mon.diskTotalGB)) GB
                net down=\(Int(mon.netDown)) B/s up=\(Int(mon.netUp)) B/s
                battery=\(String(describing: mon.battery))
                """)

        // MARK: 8 Tools
        case "tools-test":
            let d = DisplayTools.shared
            d.displayOff(); let a = d.lastAction
            d.lock(); let b = d.lastAction
            var esc = EscHold()
            let t0 = Date()
            var r: [Bool] = []
            r.append(esc.feed(keyCode: 53, down: true, at: t0))
            r.append(esc.feed(keyCode: 53, down: true, at: t0.addingTimeInterval(1.5)))
            r.append(esc.feed(keyCode: 0, down: true, at: t0.addingTimeInterval(2)))       // another key resets
            r.append(esc.feed(keyCode: 53, down: true, at: t0.addingTimeInterval(2.1)))
            r.append(esc.feed(keyCode: 53, down: true, at: t0.addingTimeInterval(5.2)))     // held 3.1 s -> escape
            var e2 = EscHold()
            _ = e2.feed(keyCode: 53, down: true, at: t0); _ = e2.feed(keyCode: 53, down: false, at: t0.addingTimeInterval(2))
            let released = e2.feed(keyCode: 53, down: true, at: t0.addingTimeInterval(4))
            CleanKeyboard.shared.start()
            out("tools-test", """
                displayOff action=\(a) (dry run in test instance)
                lock action=\(b)
                esc hold sequence=\(r) (expect false,false,false,false,true)
                esc released-then-pressed=\(released) (expect false)
                cleanKeyboard.start in test instance -> state=\(CleanKeyboard.shared.state) AXTrusted=\(AXIsProcessTrusted())
                pmset exists=\(FileManager.default.isExecutableFile(atPath: "/usr/bin/pmset"))
                """)

        // MARK: 9 Rings
        case "rings-demo":
            ActivityRings.shared.debugSet(keys: 3120, meters: 312, minutes: 148)
        case "rings-info":
            let r = ActivityRings.shared
            out("rings-info", "keys=\(r.keys) meters=\(String(format: "%.1f", r.meters)) minutes=\(r.minutes) inputPermission=\(r.hasInputPermission)")

        // MARK: 10 Stocks, pet
        case "stocks-demo":
            StocksService.shared.debugSet([
                StockQuote(symbol: "AAPL", name: "Apple", price: 342.00, changePercent: -0.28, currency: "USD"),
                StockQuote(symbol: "MSFT", name: "Microsoft", price: 512.34, changePercent: 1.12, currency: "USD"),
                StockQuote(symbol: "^GSPC", name: "S&P 500", price: 6921.5, changePercent: 0.41, currency: "USD"),
                StockQuote(symbol: "NVDA", name: "Nvidia", price: 188.2, changePercent: -1.9, currency: "USD"),
            ])
        case "stocks-live":
            Task.detached {
                let q = await StocksService.fetch("AAPL")
                let bad = await StocksService.fetch("ZZZZ-NOT-A-SYMBOL")
                await MainActor.run { out("stocks-live", "AAPL=\(String(describing: q))\nbad=\(String(describing: bad))") }
            }
        case "pet-info":
            let pet = DeskPet.shared
            guard let l = pet.sprite else { out("pet-info", "pet off"); break }
            let keys = l.animationKeys() ?? []
            let x1 = l.presentation()?.position.x ?? -1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    let x2 = l.presentation()?.position.x ?? -1
                    out("pet-info", "running=\(pet.isRunning) animations=\(keys) x(t)=\(x1) x(t+1.5s)=\(x2) moved=\(x1 != x2)")
                }
            }
        case "sleep-camera-check": break
        default: break
        }
    }
}
