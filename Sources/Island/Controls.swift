import AppKit
import SwiftUI
import Carbon.HIToolbox

// MARK: feat/controls — wiring, settings and debug commands for Keep awake, Shape, Palette, Knock.

@MainActor
enum ControlsFeature {
    private static var started = false

    /// Called once from applicationDidFinishLaunching (after the app's own onChange is set).
    static func start() {
        guard !started else { return }
        started = true
        BuiltinCommands.install()
        IntegrationCommands.install()   // integrator: Tools, timer, System, Prompter latest
        PaletteHotKey.update()
        KnockMonitor.update()
        KeepAwakeStatusItem.shared.update()
        // MARK: wip/cinema-h: "Keep screen on" became the default. Existing installs saved it as
        // off, so switch it on once; the toggle works normally afterwards.
        if !Env.defaults.bool(forKey: "KeepAwakeDisplayMigrated") {
            Env.defaults.set(true, forKey: "KeepAwakeDisplayMigrated")
            if !AppSettings.shared.prefs.keepAwakeDisplay { AppSettings.shared.prefs.keepAwakeDisplay = true }
        }
        KeepAwake.shared.resumeIfNeeded()   // MARK: wip/cinema-h
        if AppSettings.shared.prefs.pinOpen { IslandModel.shared.setExpanded(true) }
        let previous = AppSettings.shared.onChange
        AppSettings.shared.onChange = { old, new in
            previous?(old, new)
            MainActor.assumeIsolated { prefsChanged(old, new) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeepAwake.shared.shutdown() }
        }
    }

    static func prefsChanged(_ old: Prefs, _ new: Prefs) {
        if old.keepAwakeDisplay != new.keepAwakeDisplay { KeepAwake.shared.displayOptionChanged() }
        if old.keepAwakeMenuBar != new.keepAwakeMenuBar { KeepAwakeStatusItem.shared.update() }
        if old.paletteHotkey != new.paletteHotkey { PaletteHotKey.update() }
        if old.knockKey != new.knockKey {
            KnockMonitor.update()
            if new.knockKey != .off { KnockMonitor.requestPermission() } // only when the user turns it on
        }
        if old.pinOpen != new.pinOpen { IslandModel.shared.setExpanded(new.pinOpen) }
    }
}

// MARK: Settings sections (one line in SettingsView)

struct ControlsSettingsSections: View {
    @Bindable private var settings = AppSettings.shared
    @State private var trusted = KnockMonitor.trusted

    var body: some View {
        IslandShapeSettingsSection()
        Section("Keep Mac awake") {
            Toggle("Keep screen on too", isOn: $settings.prefs.keepAwakeDisplay)
            Toggle("Show cup in the menu bar", isOn: $settings.prefs.keepAwakeMenuBar)
            Text("Tap the cup in the island to keep the Mac awake; hold it for 15 min, 1 h, 2 h, 4 h, until a time, or indefinitely. Keeping the Mac awake with the lid closed needs administrator rights (pmset), so Glance does not offer it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Command palette") {
            Toggle("Open with ⌃⌥K", isOn: $settings.prefs.paletteHotkey)
            Text("⌘K also opens it while the island has keyboard focus.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Knock to open") {
            Picker("Double-tap", selection: $settings.prefs.knockKey) {
                ForEach(KnockKey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if settings.prefs.knockKey != .off {
                if trusted {
                    Text("Double-tap \(settings.prefs.knockKey.title) to open or close the island.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Knock needs Accessibility permission so Glance can see modifier keys in other apps. It never reads what you type.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Grant access…") { KnockMonitor.requestPermission(); trusted = KnockMonitor.trusted }
                        Button("Check again") { trusted = KnockMonitor.trusted; KnockMonitor.update() }
                    }
                }
            }
        }
    }
}

// MARK: Debug commands (only with --debug; reached from DebugChannel's default case)

@MainActor
enum ControlsDebug {
    static var out: URL { DebugChannel.snapshotDir }
    /// Test instances only: in-memory scripts so the palette can be tested without writing the real library.
    static var extraScripts: [PrompterScript] = []

    static func write(_ name: String, _ text: String) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? text.write(to: out.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    static func run(_ cmd: String) {
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "awake":
            // awake:toggle | awake:15 | awake:until:HH:MM | awake:forever | awake:off | awake:secs:N
            let k = KeepAwake.shared
            if arg == "toggle" { k.toggle() }
            else if arg == "off" { k.stop(reason: .user) }
            else if arg == "forever" { k.start(.indefinitely) }
            else if arg.hasPrefix("until:") { if let d = KeepAwakeParse.time(String(arg.dropFirst(6)), now: Date()) { k.start(.until(d)) } }
            else if arg.hasPrefix("secs:"), let s = Double(arg.dropFirst(5)) { k.start(.until(Date().addingTimeInterval(s))) }
            else if let m = Int(arg) { k.start(.minutes(m)) }
            write("awake-state.txt", "active=\(k.active) id=\(k.assertionID) ends=\(k.endsAt.map { "\($0)" } ?? "none") display=\(AppSettings.shared.prefs.keepAwakeDisplay) status=\(k.statusText)")
        case "awake-display":
            AppSettings.shared.prefs.keepAwakeDisplay = arg == "on"
        case "awake-menu":
            func titles(_ items: [NSMenuItem]) -> String {
                items.map { (i: NSMenuItem) -> String in i.isSeparatorItem ? "---" : (i.view != nil ? "[time picker]" : (i.state == .on ? "[x] " : "") + i.title) }.joined(separator: " | ")
            }
            let menu = KeepAwake.shared.buildMenu()
            let until = menu.items.first { $0.title == "Until a chosen time" }?.submenu?.items ?? []
            let bar = KeepAwakeStatusItem.shared.debugTitles().joined(separator: " | ")
            write("awake-menu.txt", "island menu: \(titles(menu.items))\nmenu bar: \(bar)\nuntil submenu: \(titles(until))")
        case "style":
            if let s = IslandStyle(rawValue: arg) { AppSettings.shared.prefs.islandStyle = s }
        case "geom":
            // geom:scale=110,offset=6,width=680,maxh=340,hover=false,delay=1,pin=false
            guard Env.isolated else { break }
            var p = AppSettings.shared.prefs
            for kv in arg.split(separator: ",") {
                let b = kv.split(separator: "="); guard b.count == 2, let v = Double(b[1]) ?? (b[1] == "true" ? 1 : b[1] == "false" ? 0 : nil) else { continue }
                switch b[0] {
                case "scale": p.idlePillScale = v
                case "offset": p.heightOffset = v
                case "width": p.panelWidth = v
                case "maxh": p.panelMaxHeight = v
                case "delay": p.autoCollapseDelay = v
                case "hover": p.hoverToOpen = v != 0
                case "pin": p.pinOpen = v != 0
                default: break
                }
            }
            AppSettings.shared.prefs = p
            let m = IslandModel.shared
            write("geom.txt", "style=\(p.islandStyle) size=\(m.size) closed=\(m.closedSize) inset=\(IslandGeometry.topInset) outline=\(IslandGeometry.outline(open: m.expanded, size: m.size)) collapse=\(IslandGeometry.collapseDelay) hover=\(p.hoverToOpen) pin=\(p.pinOpen) sticky=\(m.isSticky)")
        case "palette":
            // palette:open[:query] | palette:close | palette:type:<text> | palette:down | palette:up | palette:enter | palette:esc | palette:dump
            let c = CommandPaletteController.shared
            let sub = arg.split(separator: ":", maxSplits: 1).map(String.init)
            switch sub.first ?? "" {
            case "open": c.open(query: sub.count > 1 ? sub[1] : "")
            case "close", "esc": c.close()
            case "type": c.query = sub.count > 1 ? sub[1] : ""
            case "down": c.move(1)
            case "up": c.move(-1)
            case "enter": c.runSelected()
            case "key":
                // Posts a real key event through NSApp (exercises the palette's key monitor).
                if sub.count > 1, let code = UInt16(sub[1]), let w = c.debugPanel,
                   let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
                    NSApp.postEvent(e, atStart: false)
                }
            case "addscript":
                guard Env.isolated else { break }
                extraScripts = [PrompterScript(title: "Ward pilot review", text: "Good morning everyone, and thank you for joining.\nWe have three things to cover today.")]
            default: break
            }
            write("palette.txt", "open=\(c.isOpen) key=\(c.debugPanel?.isKeyWindow ?? false) query='\(c.query)' selection=\(c.selection)\n"
                  + c.results.enumerated().map { "\($0.offset == c.selection ? ">" : " ") [\($0.element.group)] \($0.element.title)" }.joined(separator: "\n"))
        case "palette-snap":
            if let w = CommandPaletteController.shared.debugPanel { snapshot(window: w, name: arg.isEmpty ? "palette" : arg) }
        case "register-test":
            // Shows the registration API: another feature adds a command.
            CommandRegistry.shared.register(PaletteCommand(id: "test.hello", title: "Say hello (registered by a test feature)", symbol: "hand.wave", group: "Test") {
                IslandModel.shared.enqueue(Peek(symbol: "hand.wave", title: "Hello from CommandRegistry", duration: 4))
                ControlsDebug.write("registered-ran.txt", "ran at \(Date())")
            })
        case "knock-sim":
            // knock-sim -> runs the detector on synthetic sequences and writes the results, then performs a knock.
            let ro = UInt16(kVK_RightOption)
            let double = KnockMonitor.debugFeed([(ro, true, 0), (ro, false, 0.08), (ro, true, 0.2), (ro, false, 0.27)])
            let slow = KnockMonitor.debugFeed([(ro, true, 0), (ro, false, 0.08), (ro, true, 0.9), (ro, false, 0.97)])
            let held = KnockMonitor.debugFeed([(ro, true, 0), (ro, false, 0.6), (ro, true, 0.7), (ro, false, 0.75)])
            let single = KnockMonitor.debugFeed([(ro, true, 0), (ro, false, 0.08)])
            let other = KnockMonitor.debugFeed([(ro, true, 0), (ro, false, 0.08), (UInt16(kVK_Option), true, 0.15), (ro, true, 0.2), (ro, false, 0.27)])
            write("knock.txt", "key=\(AppSettings.shared.prefs.knockKey.title) trusted=\(KnockMonitor.trusted) double=\(double) slow=\(slow) held=\(held) single=\(single) leftOptionBetween=\(other)")
            if arg == "fire" { KnockMonitor.knocked() }
        case "settings-snap":
            if let w = NSApp.windows.first(where: { $0.isVisible && !($0 is IslandPanel) && !($0 is PalettePanel) && $0.title.contains("Settings") })
                ?? NSApp.windows.first(where: { $0.isVisible && !($0 is IslandPanel) && !($0 is PalettePanel) && $0.frame.height > 300 }) {
                if arg.hasPrefix("scroll="), let y = Double(arg.dropFirst(7)) {
                    func find(_ v: NSView) -> NSScrollView? { if let s = v as? NSScrollView { return s }; for c in v.subviews { if let s = find(c) { return s } }; return nil }
                    if let sv = w.contentView.flatMap(find) { sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView) }
                } else { snapshot(window: w, name: arg.isEmpty ? "settings" : arg) }
            }
        case "knock-key":
            if let k = KnockKey(rawValue: arg) { AppSettings.shared.prefs.knockKey = k }
        default: break
        }
    }

    /// In-process render of one of Glance's own windows (no screen capture API).
    static func snapshot(window w: NSWindow, name: String) {
        guard let view = w.contentView, let layer = view.layer else { return }
        let scale = w.backingScaleFactor
        let size = view.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        ctx.scaleBy(x: scale, y: scale)
        if view.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let dir = out
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .utility).async {
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
