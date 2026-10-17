import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

// MARK: feat/productivity - test hooks, isolated test instances only (never active in the real app)

@MainActor
enum ToolsDebug {
    static var reportDir: URL { ToolsStore.directory.deletingLastPathComponent() }

    static func report(_ name: String, _ text: String) {
        try? text.write(to: reportDir.appendingPathComponent("tools-report-\(name).txt"), atomically: true, encoding: .utf8)
    }

    static func run(_ cmd: String) {
        guard Env.isolated else { return }
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "open":
            IslandModel.shared.pinned = true
            ToolsModel.shared.open(ToolsTab(rawValue: arg) ?? .calc)
        case "calc": CalcState.shared.input = arg
        case "calc-clear": CalcState.shared.input = ""; CalcState.shared.history = []
        case "calc-hist":
            // Adds history rows exactly as pressing Return would.
            for expr in arg.components(separatedBy: ";") where !expr.isEmpty {
                let st = CalcState.shared
                let o = CalcEngine.evaluate(expr, ans: st.ans, degrees: st.degrees, rates: CurrencyRates.shared.rates)
                switch o {
                case .value(let v, let d): st.history.insert(CalcEntry(input: expr, output: d, copy: CalcEngine.plain(v)), at: 0); st.ans = v
                case .conversion(let d, let c, _): st.history.insert(CalcEntry(input: expr, output: d, copy: c), at: 0); if let v = Double(c) { st.ans = v }
                default: break
                }
            }
        case "calc-test": calcTest()
        case "rates-refresh": CurrencyRates.shared.refreshIfNeeded(force: true)
        case "rates-offline": CurrencyRates.shared.simulateOffline = arg == "on"
        case "rates-report":
            let r = CurrencyRates.shared
            report("rates", "status=\(r.status)\ncount=\(r.cache.rates.count)\nfetched=\(r.cache.fetched)\nGBP=\(r.cache.rates["GBP"] ?? 0) EUR=\(r.cache.rates["EUR"] ?? 0)\nfile=\(ToolsStore.url("rates.json").path)\n")
        case "emoji": ToolsViewState.shared.emojiQuery = arg
        case "emoji-test":
            let c = EmojiCatalog.shared
            c.loadIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                var out = "total=\(c.items.count)\n"
                for q in ["heart", "fire", "party", "thumbs up", "lol", "flag", "xyzzy"] {
                    let r = c.search(q)
                    out += "\(q): \(r.count) first=\(r.prefix(6).map(\.emoji).joined())\n"
                }
                report("emoji", out)
            }
        case "emoji-pick":
            // Simulates a click: recents + pasteboard (paste itself never fires in test mode).
            let p = ToolsPrefs.shared
            var r = p.data.recentEmoji; r.removeAll { $0 == arg }; r.insert(arg, at: 0); p.data.recentEmoji = Array(r.prefix(24))
        case "notes-test": notesTest()
        case "notes-new":
            NotesStore.shared.loadIfNeeded()
            NotesStore.shared.add()
            if let id = NotesStore.shared.selected { NotesStore.shared.edit(id, arg.replacingOccurrences(of: "\\n", with: "\n")) }
        case "apps": ToolsViewState.shared.appQuery = arg
        case "apps-report":
            let i = AppIndex.shared
            i.loadIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                report("apps", "apps=\(i.apps.count)\nfavourites=\(ToolsPrefs.shared.data.favouriteApps)\nsearch 'saf': \(i.search("saf").map(\.name))\nsearch 'term': \(i.search("term").map(\.name))\n")
            }
        case "search-test":
            var out = ""
            for e in SearchEngines.all { out += "\(e.name): \(SearchEngines.url(engine: e, query: "swift concurrency & more?")?.absoluteString ?? "nil")\n" }
            report("search", out)
        case "search-key":
            // Sends a real Command-<digit> key event into the island panel (in-process, no Accessibility needed).
            guard let w = NSApp.windows.first(where: { $0 is IslandPanel }), let ch = arg.first else { break }
            let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, characters: String(ch), charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0)
            let handled = ev.map { w.performKeyEquivalent(with: $0) } ?? false
            report("search-key", "key=cmd-\(arg) handled=\(handled) isKey=\(w.isKeyWindow) engine=\(ToolsPrefs.shared.data.searchEngine)\n")
        case "reminders-tick":
            let r = RemindersService.shared
            if let first = r.items.first(where: { !$0.done }) { r.toggle(first) }
        case "reminders-add": RemindersService.shared.add(arg)
        case "search-engine": ToolsPrefs.shared.data.searchEngine = arg
        case "shortcuts-fake":
            ShortcutsService.shared.fakeNames = arg.split(separator: ",").map(String.init)
            ShortcutsService.shared.loadIfNeeded(force: true)
        case "shortcuts-real":
            ShortcutsService.shared.fakeNames = nil
            ShortcutsService.shared.loadIfNeeded(force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                report("shortcuts", "count=\(ShortcutsService.shared.names.count) names=\(ShortcutsService.shared.names.prefix(10))\n")
            }
        case "shortcuts-run":
            // Runs a name that does not exist: proves the plumbing and failure path without touching your real shortcuts.
            ShortcutsService.shared.run(arg)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let r = ShortcutsService.shared.lastResult
                report("shortcuts-run", "name=\(r?.name ?? "-") ok=\(r.map { String($0.ok) } ?? "nil")\n")
            }
        case "timer-start": QuickTimer.shared.start(minutes: Double(arg) ?? 1)
        case "timer-secs": QuickTimer.shared.start(minutes: (Double(arg) ?? 3) / 60)
        case "timer-report":
            report("timer", "active=\(QuickTimer.shared.active) running=\(QuickTimer.shared.running) remaining=\(QuickTimer.shared.remaining())\n")
        case "stopwatch": arg == "lap" ? Stopwatch.shared.lap() : (arg == "reset" ? Stopwatch.shared.reset() : Stopwatch.shared.toggle())
        case "sound":
            FocusSounds.shared.muteForTesting = true   // never audible during tests
            if arg == "off" { FocusSounds.shared.stop() } else if let k = FocusSounds.Kind(rawValue: arg) { FocusSounds.shared.start(k) }
        case "translate-status": translateStatus()
        case "focus-report":
            let f = FocusMonitor.shared
            report("focus", "active=\(f.active ?? "nil") available=\(f.available)\n")
        default: break
        }
    }

    private static func calcTest() {
        let sample: [String: Double] = ["USD": 1, "GBP": 0.75, "EUR": 0.86, "JPY": 150]
        let rates = CurrencyRates.shared.rates.isEmpty ? sample : CurrencyRates.shared.rates
        let cases = ["2+3*4", "(2+3)*4", "2^10", "10/4", "100 + 10%", "200 - 25%", "15% of 80", "50%", "17 % 5", "sqrt(144)", "sqrt 2 * sqrt 2",
                     "sin(30)", "cos(pi)", "ln(e)", "log(1000)", "5!", "1,234.5 * 2", "2(3+4)", "-3^2", "1/0", "2 +", "ans * 2", "abs(-7.5)", "round(2.6)", "1e3 + 1",
                     "5 ft in cm", "10 km to mi", "100 c to f", "32 f to c", "0 c to k", "2.5 kg to lb", "12 in to cm", "1 h to min", "90 min to h", "2 wk in d",
                     "1 GB to MB", "1 GiB to MB", "8 bit to B", "1 MB to KB", "5 kg to m", "100 usd to gbp", "$50 to eur", "£20 to usd", "1000 jpy to gbp", "10 abc to usd"]
        var out = "ans=42 degrees=false rates_source=\(CurrencyRates.shared.rates.isEmpty ? "sample" : "cached/live (\(rates.count) currencies)")\n"
        for c in cases {
            var o = CalcEngine.evaluate(c, ans: 42, degrees: false, rates: rates)
            if c == "sin(30)" { o = CalcEngine.evaluate(c, ans: 42, degrees: true, rates: rates); out += "[deg] " }
            let text: String
            switch o {
            case .value(_, let d): text = d
            case .conversion(let d, _, _): text = d
            case .error(let m): text = "ERROR(\(m))"
            case .empty: text = "(empty)"
            }
            out += "\(c)  =>  \(text)\n"
        }
        report("calc", out)
    }

    private static func notesTest() {
        let s = NotesStore.shared
        s.loadIfNeeded()
        s.add()
        if let id = s.selected { s.edit(id, "Autosave test\nsecond line") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let url = ToolsStore.url("notes.json")
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let perm = (attrs?[.posixPermissions] as? NSNumber).map { String($0.intValue, radix: 8) } ?? "missing"
            let dirAttrs = try? FileManager.default.attributesOfItem(atPath: ToolsStore.directory.path)
            let dperm = (dirAttrs?[.posixPermissions] as? NSNumber).map { String($0.intValue, radix: 8) } ?? "missing"
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            report("notes", "file=\(url.path)\nfile_mode=\(perm)\ndir_mode=\(dperm)\nnotes_in_memory=\(s.notes.count)\ncontains_text=\(content.contains("Autosave test"))\n")
        }
    }

    private static func translateStatus() {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            Task {
                var out = ""
                let a = LanguageAvailability()
                out += "supported languages=\(await a.supportedLanguages.count)\n"
                for t in ["es", "fr", "de"] {
                    out += "en->\(t): \(await a.status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: t)))\n"
                }
                report("translate", out)
            }
        }
        #endif
    }
}
