import AppKit
import SwiftUI
import Carbon.HIToolbox
import Observation

// MARK: feat/controls — Command palette (⌃⌥K anywhere, ⌘K while the island has focus)

/// One palette entry. Other features register these with `CommandRegistry.shared`.
struct PaletteCommand: Identifiable {
    /// Stable, unique id (e.g. "keepawake.toggle"). Registering the same id replaces the old one.
    let id: String
    var title: String
    var subtitle: String? = nil
    var symbol: String = "command"
    /// Extra words that should match (not shown).
    var keywords: [String] = []
    /// Section label shown on the right ("Go to", "Keep awake", "Shortcuts"...).
    var group: String = "Glance"
    /// Lower sorts first among equal scores.
    var priority: Int = 0
    /// Keep the palette open after running (rare).
    var keepsOpen = false
    let action: @MainActor () -> Void
}

/// Registration API for palette commands.
///
/// ```swift
/// CommandRegistry.shared.register(PaletteCommand(id: "notes.new", title: "New note", symbol: "note.text") { ... })
/// CommandRegistry.shared.registerProvider(id: "notes.search") { query in [...] }   // dynamic, per query
/// CommandRegistry.shared.unregister(id: "notes.new")
/// ```
/// Static commands may also be closures that build their title at open time (`registerDynamic`),
/// so labels like "Start focus timer" / "Pause focus timer" are always current.
@MainActor
final class CommandRegistry {
    static let shared = CommandRegistry()

    private var builders: [(id: String, build: @MainActor () -> [PaletteCommand])] = []
    private var providers: [(id: String, provide: @MainActor (String) -> [PaletteCommand])] = []

    /// A fixed command.
    func register(_ c: PaletteCommand) { registerDynamic(id: c.id) { [c] } }

    /// Commands rebuilt every time the palette opens or the query changes (cheap closures only).
    func registerDynamic(id: String, _ build: @escaping @MainActor () -> [PaletteCommand]) {
        builders.removeAll { $0.id == id }
        builders.append((id, build))
    }

    /// Commands that depend on what was typed (e.g. "awake until 17:30").
    func registerProvider(id: String, _ provide: @escaping @MainActor (String) -> [PaletteCommand]) {
        providers.removeAll { $0.id == id }
        providers.append((id, provide))
    }

    func unregister(id: String) {
        builders.removeAll { $0.id == id }
        providers.removeAll { $0.id == id }
    }

    func allCommands(query: String) -> [PaletteCommand] {
        builders.flatMap { $0.build() } + providers.flatMap { $0.provide(query) }
    }

    /// Ranked, fuzzy-filtered results.
    func search(_ query: String, limit: Int = 40) -> [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = allCommands(query: q)
        if q.isEmpty { return Array(all.sorted { $0.priority < $1.priority }.prefix(limit)) }
        var scored: [(PaletteCommand, Int)] = []
        for c in all {
            var best = FuzzyMatch.score(q, c.title)
            for k in c.keywords + [c.group] { if let s = FuzzyMatch.score(q, k) { best = max(best ?? Int.min, s - 8) } }
            if let s = best { scored.append((c, s)) }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.priority < $1.0.priority }
        return Array(scored.prefix(limit).map(\.0))
    }
}

/// Subsequence matcher: every query character must appear in order. Bonuses for prefix,
/// word starts and runs of consecutive characters; penalty for gaps.
enum FuzzyMatch {
    static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        let t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        var qi = 0, score = 0, last = -2, firstHit = -1
        for (i, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            if firstHit < 0 { firstHit = i }
            let wordStart = i == 0 || !(t[i - 1].isLetter || t[i - 1].isNumber)
            score += 10
            if wordStart { score += 12 }
            if i == last + 1 { score += 8 } else if last >= 0 { score -= min(i - last, 6) }
            last = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        if firstHit == 0 { score += 15 }
        if t.starts(with: q) { score += 20 }
        score -= max(0, t.count - q.count) / 4   // prefer shorter titles
        return score
    }
}

// MARK: Built-in commands

@MainActor
enum BuiltinCommands {
    static func install() {
        let r = CommandRegistry.shared
        let tabs: [(ExpandedPage, String, String, [String])] = [
            (.widgets, "Home", "house", ["widgets", "cards"]),
            (.clipboard, "Clipboard", "doc.on.clipboard", ["paste", "history", "copy"]),
            (.shelf, "Shelf", "tray", ["files", "drop"]),
            (.today, "Today", "checklist", ["todo", "tasks"]),
            (.prompter, "Prompter", "text.viewfinder", ["teleprompter", "script"]),
        ]
        r.registerDynamic(id: "builtin.tabs") {
            tabs.filter { $0.0 != .today || AppSettings.shared.prefs.todoEnabled }.enumerated().map { i, t in
                PaletteCommand(id: "tab.\(t.1)", title: "Go to \(t.1)", symbol: t.2, keywords: [t.1] + t.3, group: "Go to", priority: 10 + i) {
                    IslandModel.shared.openFromCommand(page: t.0)
                }
            }
        }
        r.registerDynamic(id: "builtin.timer") {
            let ft = FocusTimer.shared
            var out = [PaletteCommand(id: "timer.toggle", title: ft.running ? "Pause focus timer" : "Start focus timer",
                                      subtitle: ft.label, symbol: ft.running ? "pause.circle" : "timer",
                                      keywords: ["focus", "pomodoro", "timer"], group: "Timer", priority: 5) { FocusTimer.shared.toggle() }]
            if ft.running || ft.remaining != ft.halfLength {
                out.append(PaletteCommand(id: "timer.reset", title: "Stop focus timer", symbol: "stop.circle",
                                          keywords: ["reset", "focus", "timer"], group: "Timer", priority: 6) { FocusTimer.shared.reset() })
            }
            return out
        }
        r.registerDynamic(id: "builtin.keepawake") {
            let k = KeepAwake.shared
            var out = [PaletteCommand(id: "keepawake.toggle", title: k.active ? "Turn off keep awake" : "Keep Mac awake",
                                      subtitle: k.statusText, symbol: k.active ? "cup.and.saucer.fill" : "cup.and.saucer",
                                      keywords: ["caffeine", "awake", "sleep", "amphetamine"], group: "Keep awake", priority: 1) { KeepAwake.shared.toggle() }]
            for (i, d) in (KeepAwakeDuration.presets + [.indefinitely]).enumerated() {
                out.append(PaletteCommand(id: "keepawake.\(d.title)", title: "Keep awake for \(d.title)".replacingOccurrences(of: "for Indefinitely", with: "indefinitely"),
                                          symbol: "cup.and.saucer", keywords: ["caffeine", "awake", "sleep"], group: "Keep awake", priority: 40 + i) {
                    KeepAwake.shared.start(d)
                })
            }
            return out
        }
        // "awake until 17:30", "until 5pm", "awake 45m", "awake 3h"
        r.registerProvider(id: "builtin.keepawake.parse") { q in
            guard let d = KeepAwakeParse.duration(q) else { return [] }
            return [PaletteCommand(id: "keepawake.parsed", title: "Keep awake \(d.title.lowercased().hasPrefix("until") ? d.title.lowercased() : "for \(d.title)")",
                                   symbol: "cup.and.saucer.fill", group: "Keep awake", priority: -1) { KeepAwake.shared.start(d) }]
        }
        r.registerDynamic(id: "builtin.prompter") {
            (PrompterLibrary.shared.scripts + ControlsDebug.extraScripts).prefix(30).enumerated().map { i, s in
                PaletteCommand(id: "prompter.\(s.id)", title: "Start script: \(s.title)", subtitle: s.preview, symbol: "text.viewfinder",
                               keywords: ["prompter", "teleprompter", "read"], group: "Prompter", priority: 60 + i) { Prompter.shared.start(s) }
            }
        }
        r.register(PaletteCommand(id: "football.goal", title: "Play goal celebration", symbol: "soccerball", keywords: ["football", "celebrate", "goal"],
                                  group: "Football", priority: 30) { FootballService.shared.playLastGoal() })
        r.register(PaletteCommand(id: "app.settings", title: "Open Settings", symbol: "gearshape", keywords: ["preferences", "options"],
                                  group: "Glance", priority: 20) { AppDelegate.shared?.showSettings() })
        r.registerDynamic(id: "app.hide") {
            let hidden = AppSettings.shared.prefs.islandHidden
            return [PaletteCommand(id: "app.hide", title: hidden ? "Show Glance" : "Hide Glance", symbol: "eye", group: "Glance", priority: 80) {
                AppSettings.shared.prefs.islandHidden.toggle()
            }]
        }
        r.register(PaletteCommand(id: "app.quit", title: "Quit Glance", symbol: "power", keywords: ["exit", "close"], group: "Glance", priority: 99) {
            AppDelegate.quitByUser()
        })
        r.registerDynamic(id: "builtin.shortcuts") {
            ShortcutsCatalog.shared.names.enumerated().map { i, name in
                PaletteCommand(id: "shortcut.\(name)", title: "Run shortcut: \(name)", symbol: "square.stack.3d.up", keywords: ["shortcuts", name],
                               group: "Shortcuts", priority: 200 + i) { ShortcutsCatalog.shared.run(name) }
            }
        }
    }
}

enum KeepAwakeParse {
    /// Understands "until 17:30", "until 5pm", "until 5.15 pm", "45m", "45 min", "3h", "1.5 h".
    static func duration(_ raw: String, now: Date = Date()) -> KeepAwakeDuration? {
        let q = raw.lowercased().replacingOccurrences(of: "keep awake", with: "").replacingOccurrences(of: "awake", with: "")
            .replacingOccurrences(of: "for", with: "").trimmingCharacters(in: .whitespaces)
        if let r = q.range(of: "until") {
            let t = q[r.upperBound...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
            return time(t, now: now).map { .until($0) }
        }
        let compact = q.replacingOccurrences(of: " ", with: "")
        for (suffix, mult) in [("minutes", 1.0), ("minute", 1.0), ("mins", 1.0), ("min", 1.0), ("m", 1.0), ("hours", 60.0), ("hour", 60.0), ("hrs", 60.0), ("h", 60.0)] {
            if compact.hasSuffix(suffix), let v = Double(compact.dropLast(suffix.count)), v > 0, v * mult <= 24 * 60 {
                return .minutes(Int((v * mult).rounded()))
            }
        }
        return nil
    }

    static func time(_ t: String, now: Date) -> Date? {
        var s = t
        var pm: Bool? = nil
        if s.hasSuffix("pm") { pm = true; s.removeLast(2) } else if s.hasSuffix("am") { pm = false; s.removeLast(2) }
        let bits = s.split(whereSeparator: { $0 == ":" || $0 == "." }).map(String.init)
        guard let h0 = bits.first.flatMap({ Int($0) }), bits.count <= 2 else { return nil }
        let m = bits.count == 2 ? (Int(bits[1]) ?? -1) : 0
        var h = h0
        if let pm { guard (1...12).contains(h) else { return nil }; h = h % 12 + (pm ? 12 : 0) }
        guard (0...23).contains(h), (0...59).contains(m) else { return nil }
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: now)
    }
}

/// Apple Shortcuts via the `shortcuts` command-line tool. Listed off the main thread when the
/// palette opens (at most once a minute), so it costs nothing while idle.
@Observable @MainActor
final class ShortcutsCatalog {
    static let shared = ShortcutsCatalog()
    private(set) var names: [String] = []
    @ObservationIgnored private var lastLoad = Date.distantPast
    @ObservationIgnored private var loading = false

    func refreshIfStale() {
        guard !loading, Date().timeIntervalSince(lastLoad) > 60 else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let out = Self.runTool(["list"]) ?? ""
            let list = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.names = list
                    self.lastLoad = Date()
                    self.loading = false
                    CommandPaletteController.shared.refreshResults()
                }
            }
        }
    }

    func run(_ name: String) {
        IslandModel.shared.enqueue(Peek(symbol: "square.stack.3d.up", title: "Running \(name)", duration: 2))
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.runTool(["run", name])
        }
    }

    nonisolated static func runTool(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

extension IslandModel {
    /// Opens the island on a page and keeps it open until the pointer visits it or a click lands elsewhere.
    func openFromCommand(page p: ExpandedPage) {
        dismissPeek()
        withAnimation(Self.openSpring) {
            editing = false
            page = p
            openedByHotkey = true
        }
        setExpanded(true)
    }
}

// MARK: Palette window

final class PalettePanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: CommandPaletteController.size.width, height: CommandPaletteController.size.height),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@Observable @MainActor
final class CommandPaletteController {
    static let shared = CommandPaletteController()
    static let size = CGSize(width: 600, height: 420)

    var query = "" { didSet { if query != oldValue { selection = 0; refreshResults() } } }
    private(set) var results: [PaletteCommand] = []
    var selection = 0
    var isOpen: Bool { panel != nil }

    @ObservationIgnored fileprivate var panel: PalettePanel?
    @ObservationIgnored fileprivate var openedAt = Date.distantPast
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var resignObs: NSObjectProtocol?

    func toggle() { isOpen ? close() : open() }

    func open(query q: String = "") {
        ShortcutsCatalog.shared.refreshIfStale()
        query = q
        refreshResults()
        if panel == nil {
            let p = PalettePanel()
            let host = NSHostingView(rootView: CommandPaletteView())
            host.sizingOptions = []
            p.contentView = host
            panel = p
            installKeys()
            resignObs = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let c = CommandPaletteController.shared
                    // A focus change racing the hotkey (e.g. the front app finishing a key event): take it back once.
                    if Date().timeIntervalSince(c.openedAt) < 0.5 { c.panel?.makeKey(); return }
                    c.close() // clicked elsewhere
                }
            }
        }
        position()
        openedAt = Date()
        lastPointer = NSEvent.mouseLocation
        panel?.orderFrontRegardless()
        panel?.makeKey()
    }

    func close() {
        guard let p = panel else { return }
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
        if let o = resignObs { NotificationCenter.default.removeObserver(o); resignObs = nil }
        panel = nil
        p.orderOut(nil)
        p.contentView = nil   // tear down the SwiftUI tree; nothing remains while closed
    }

    private func position() {
        guard let p = panel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let f = screen?.visibleFrame ?? SafeScreen.primary.visibleFrame
        let s = Self.size
        // Centred horizontally, a little above the middle (like Spotlight).
        p.setFrame(NSRect(x: f.midX - s.width / 2, y: f.minY + f.height * 0.62 - s.height + 60, width: s.width, height: s.height), display: true)
    }

    func refreshResults() {
        results = CommandRegistry.shared.search(query)
        selection = min(selection, max(0, results.count - 1))
        if query.isEmpty || selection >= results.count { selection = 0 }
    }

    /// Rows sliding under a still pointer (while typing) must not steal the keyboard selection:
    /// only a pointer that has actually moved selects.
    @ObservationIgnored private var lastPointer = NSPoint(x: -1, y: -1)
    func hover(_ i: Int) {
        let p = NSEvent.mouseLocation
        defer { lastPointer = p }
        guard p != lastPointer, lastPointer.x >= 0 else { return }
        selection = i
    }

    func move(_ d: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + d + results.count) % results.count
    }

    func runSelected() {
        guard results.indices.contains(selection) else { return }
        run(results[selection])
    }

    func run(_ c: PaletteCommand) {
        if !c.keepsOpen { close() }
        // After the palette has gone, so the island and panels can take focus.
        DispatchQueue.main.async { c.action() }
    }

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let code = Int(e.keyCode)
            let shift = e.modifierFlags.contains(.shift)
            let ctrl = e.modifierFlags.contains(.control)
            let chars = e.charactersIgnoringModifiers
            let windowNumber = e.windowNumber
            let handled: Bool = MainActor.assumeIsolated {
                let c = CommandPaletteController.shared
                guard let p = c.panel, p.windowNumber == windowNumber else { return false }
                switch code {
                case kVK_Escape: c.close()
                case kVK_DownArrow: c.move(1)
                case kVK_UpArrow: c.move(-1)
                case kVK_Return, kVK_ANSI_KeypadEnter: c.runSelected()
                case kVK_Tab: c.move(shift ? -1 : 1)
                default:
                    if ctrl, chars == "n" { c.move(1) } else if ctrl, chars == "p" { c.move(-1) } else { return false }
                }
                return true
            }
            return handled ? nil : e
        }
    }

    /// Debug: the panel (for in-process snapshots).
    var debugPanel: NSWindow? { panel }
}

struct CommandPaletteView: View {
    @Bindable private var c = CommandPaletteController.shared
    @FocusState private var focused: Bool

    var body: some View {
        let theme = Theme.current
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(theme.secondary)
                TextField("Type a command", text: $c.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(theme.primary)
                    .focused($focused)
                    .accessibilityLabel("Command search")
                Text("esc").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.tertiary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.tertiary, lineWidth: 0.8))
            }
            .padding(.horizontal, 18).frame(height: 54)
            Divider().opacity(0.5)
            if c.results.isEmpty {
                Text("No matching commands").font(.system(size: 13)).foregroundStyle(theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(c.results.enumerated()), id: \.element.id) { i, cmd in
                                PaletteRow(title: cmd.title, subtitle: cmd.subtitle, symbol: cmd.symbol, group: cmd.group,
                                           selected: i == c.selection, theme: theme)
                                    .id(cmd.id)
                                    .onTapGesture { c.run(cmd) }
                                    .onHover { if $0 { c.hover(i) } }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: c.selection) { _, s in
                        if c.results.indices.contains(s) { proxy.scrollTo(c.results[s].id) }
                    }
                }
            }
        }
        .frame(width: CommandPaletteController.size.width, height: CommandPaletteController.size.height)
        .background(
            ZStack {
                VisualEffectBlur(dark: theme.dark)
                theme.pill.opacity(theme.dark ? 0.55 : 0.5)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.cardStroke, lineWidth: 0.8))
        .environment(\.colorScheme, theme.dark ? .dark : .light)
        .onAppear { focused = true }
    }

}

struct PaletteRow: View {
    let title: String
    let subtitle: String?
    let symbol: String
    let group: String
    let selected: Bool
    let theme: Theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? theme.onAccent : theme.primary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? theme.accent : theme.card))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(theme.primary).lineLimit(1)
                if let s = subtitle, !s.isEmpty {
                    Text(s).font(.system(size: 11)).foregroundStyle(theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(group).font(.system(size: 11)).foregroundStyle(theme.tertiary)
            if selected { Image(systemName: "return").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondary) }
        }
        .padding(.horizontal, 10).frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? theme.accent.opacity(theme.dark ? 0.22 : 0.14) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// ⌃⌥K global hotkey (Carbon, no permission) and ⌘K while the island panel has keyboard focus.
@MainActor
enum PaletteHotKey {
    private static var localMonitor: Any?

    static func update() {
        if AppSettings.shared.prefs.paletteHotkey {
            HotKeyCenter.register(id: 20, keyCode: kVK_ANSI_K, modifiers: controlKey | optionKey) { CommandPaletteController.shared.toggle() }
        } else {
            HotKeyCenter.unregister(id: 20)
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard e.window is IslandPanel,
                      e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      e.charactersIgnoringModifiers?.lowercased() == "k" else { return e }
                MainActor.assumeIsolated { CommandPaletteController.shared.open() }
                return nil
            }
        }
    }
}
