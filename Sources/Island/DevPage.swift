// MARK: feat/claude-dev
// Developer page in the expanded island (Claude usage, Terminal, Homebrew), feature lifecycle,
// debug commands and offscreen snapshots for this branch.

import AppKit
import SwiftUI

struct DevPage: View {
    let theme: Theme
    @Bindable private var settings = AppSettings.shared
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(DevTab.allCases) { tab in
                    let selected = settings.prefs.dev.lastTab == tab
                    Button {
                        withAnimation(IslandModel.openSpring) { settings.prefs.dev.lastTab = tab }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: tab.symbol).font(.system(size: 10, weight: .medium))
                            Text(tab.title).font(.system(size: 11, weight: .medium))
                            if tab == .terminal && NotchTerminal.shared.isRunning {
                                Circle().fill(Color.orange).frame(width: 5, height: 5)
                            }
                            if tab == .brew && !Homebrew.shared.packages.isEmpty {
                                Text("\(Homebrew.shared.packages.count)").font(.system(size: 9, weight: .bold).monospacedDigit())
                                    .foregroundStyle(theme.onAccent).padding(.horizontal, 4).background(Capsule().fill(theme.accent))
                            }
                        }
                        .foregroundStyle(selected ? theme.primary : theme.secondary)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background {
                            if selected {
                                Capsule().fill(theme.accent.opacity(theme.dark ? 0.26 : 0.16))
                                    .overlay(Capsule().strokeBorder(theme.accent.opacity(0.45), lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "devtab", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            Group {
                switch settings.prefs.dev.lastTab {
                case .claude: ClaudeUsagePane(theme: theme)
                case .terminal: TerminalPane(theme: theme)
                case .brew: BrewPane(theme: theme)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.bottom, 16)
    }

    @MainActor static func open(_ tab: DevTab) {
        let m = IslandModel.shared
        AppSettings.shared.prefs.dev.lastTab = tab
        withAnimation(IslandModel.openSpring) { m.editing = false; m.page = .dev }
        m.setExpanded(true)
    }
}

/// Start / stop / preference changes for this branch's features.
@MainActor
enum DevFeatures {
    static func start() {
        if AppSettings.shared.prefs.dev.usageEnabled { ClaudeUsage.shared.start() }
    }

    static func prefsChanged(_ old: DevPrefs, _ new: DevPrefs) {
        if old.usageEnabled != new.usageEnabled { new.usageEnabled ? ClaudeUsage.shared.start() : ClaudeUsage.shared.stop() }
        if old.metric != new.metric || old.sessionTokenBudget != new.sessionTokenBudget || old.sessionPromptBudget != new.sessionPromptBudget
            || old.weekTokenBudget != new.weekTokenBudget || old.weekPromptBudget != new.weekPromptBudget
            || old.weekResetWeekday != new.weekResetWeekday || old.weekResetHour != new.weekResetHour { ClaudeUsage.shared.recompute() }
        if old.longCommands != new.longCommands, !new.longCommands { LongCommands.shared.clearAll() }
        if old.devPage != new.devPage, !new.devPage, IslandModel.shared.page == .dev {
            withAnimation(IslandModel.openSpring) { IslandModel.shared.page = .widgets }
        }
    }

    static func terminate() { NotchTerminal.shared.terminateOnQuit(); Homebrew.shared.stopUpgrade() }

    // MARK: Debug channel (only with --debug); returns true if handled.

    static func debug(_ cmd: String) -> Bool {
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let m = IslandModel.shared
        switch parts.first ?? "" {
        case "dev":   // dev:claude | dev:terminal | dev:brew
            DevPage.open(DevTab(rawValue: arg) ?? .claude)
        case "usage-demo":   // usage-demo:<session%>,<week%>
            let v = arg.split(separator: ",").compactMap { Double($0) }
            ClaudeUsage.shared.debugDemo(sessionFraction: (v.first ?? 42) / 100, weekFraction: (v.count > 1 ? v[1] : 31) / 100)
        case "usage-live": ClaudeUsage.shared.debugEndDemo()
        case "usage-dump":   // writes numbers only (no message content)
            let s = ClaudeUsage.shared.snapshot
            func line(_ n: String, _ t: UsageTotals) -> String {
                "\(n): calls=\(t.calls) prompts=\(t.prompts) in=\(t.input) out=\(t.output) cacheWrite=\(t.cacheWrite) cacheRead=\(t.cacheRead) counted=\(t.counted) cost=\(String(format: "%.2f", t.cost))"
            }
            let text = [line("session", s.session.totals), "session.active=\(s.session.active) fraction=\(s.session.fraction) projected=\(s.session.projected ?? -1) start=\(Date(timeIntervalSince1970: s.session.start))",
                        line("week", s.week.totals), "week.fraction=\(s.week.fraction)", line("today", s.today),
                        "records=\(s.recordCount) files=\(s.stats.files) read=\(s.stats.filesRead) bytes=\(s.stats.bytesRead) scanSeconds=\(s.stats.seconds)"].joined(separator: "\n")
            write(text, "usage-dump.txt")
        case "pref-dev":   // pref-dev:<name>=<value> (isolated test instances only; nothing is saved)
            guard Env.isolated else { break }
            let kv = arg.split(separator: "=", maxSplits: 1).map(String.init); guard kv.count == 2 else { break }
            var p = AppSettings.shared.prefs
            switch kv[0] {
            case "usageCard": p.dev.usageCard = kv[1] == "true"
            case "usageEnabled": p.dev.usageEnabled = kv[1] == "true"
            case "longCommandSeconds": p.dev.longCommandSeconds = Int(kv[1]) ?? 30
            case "brewUpgrades": p.dev.brewUpgrades = kv[1] == "true"
            case "islandHidden": p.islandHidden = kv[1] == "true"
            case "terminalDirectory": p.dev.terminalDirectory = kv[1]
            case "plan": p.dev.plan = ClaudePlan(rawValue: kv[1]) ?? .pro; p.dev.applyPlanDefaults()
            default: break
            }
            AppSettings.shared.prefs = p
        case "term-type": NotchTerminal.shared.input = arg
        case "term-run": NotchTerminal.shared.run()           // same path as pressing Return
        case "term-ctrlc": NotchTerminal.shared.interrupt()
        case "term-up": NotchTerminal.shared.historyUp()
        case "term-dump":
            let t = NotchTerminal.shared
            write("input=\(t.input) running=\(t.isRunning) status=\(t.lastStatus ?? "-") dir=\(t.directory) history=\(t.history)\n---\n\(t.output)", "term-dump.txt")
        case "brew-refresh": Homebrew.shared.refresh()
        case "brew-ask": Homebrew.shared.askConfirm(arg.isEmpty ? "*" : arg)
        case "brew-confirm": Homebrew.shared.confirmUpgrade()
        case "brew-dump":
            let b = Homebrew.shared
            write("count=\(b.packages.count) upgrading=\(b.upgrading ?? "-") confirming=\(b.confirming ?? "-") results=\(b.results)\nprogress=\(b.progressLine)\n" +
                  b.packages.map { "\($0.name) \($0.installed) -> \($0.current) cask=\($0.cask)" }.joined(separator: "\n") + "\n---log\n\(b.log)", "brew-dump.txt")
        case "lc-fake":   // lc-fake:<seconds>:<exit>  simulate a Bash call end to end (pre now, post after seconds)
            let bits = arg.split(separator: ":").map(String.init)
            let secs = Double(bits.first ?? "") ?? 3, code = Int(bits.count > 1 ? bits[1] : "0") ?? 0
            let id = "debug-" + UUID().uuidString
            LongCommands.shared.pre(["tool_name": "Bash", "tool_use_id": id, "tool_input": ["command": "npm run build"]], project: "island", session: "debug")
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                MainActor.assumeIsolated {
                    var msg: [String: Any] = ["tool_name": "Bash", "tool_use_id": id, "tool_input": ["command": "npm run build"]]
                    if code != 0 { msg["error"] = "Exit code \(code)\nbuild failed" }
                    LongCommands.shared.post(msg, failed: code != 0, session: "debug")
                }
            }
        case "lc-state":
            let lc = LongCommands.shared
            write("running=\(lc.running.map { "\($0.command) shown=\($0.shown) waiting=\($0.waitingForPermission)" }) peek=\(m.peek.map { "\($0.title) | \($0.subtitle ?? "")" } ?? "-")", "lc-state.txt")
        case "peek-state":
            write("peek=\(m.peek.map { "\($0.title) | \($0.subtitle ?? "")" } ?? "-")", "peek-state.txt")
        case "snap":   // snap:<name>  offscreen render of the island root view
            snapshotIsland(name: arg.isEmpty ? "island" : arg)
        case "snap-settings":
            snapshotView(DeveloperSettingsFrame(), size: CGSize(width: 460, height: 900), name: arg.isEmpty ? "settings-developer" : arg)
        default: return false
        }
        return true
    }

    static var outDir: URL {
        if let d = ProcessInfo.processInfo.environment["GLANCE_SNAPSHOT_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        return DebugChannel.snapshotDir
    }

    private static func write(_ s: String, _ name: String) {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try? s.write(to: outDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Renders the island's own SwiftUI root view in an offscreen window (no screen capture).
    static func snapshotIsland(name: String) {
        let size = IslandMetrics.window
        let view = IslandRootView().frame(width: size.width, height: size.height)
            .background(Color(white: 0.55))
        snapshotView(view, size: CGSize(width: size.width, height: size.height), name: name)
    }

    static func snapshotView<V: View>(_ view: V, size: CGSize, name: String) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = host
        win.alphaValue = 0.0
        win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        // Give SwiftUI two run-loop turns to settle (onAppear, layout), then draw.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                    try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent("\(name).png"))
                }
                win.orderOut(nil)
                win.contentView = nil
            }
        }
    }
}

/// Settings section on its own (for snapshots).
private struct DeveloperSettingsFrame: View {
    var body: some View {
        Form { DeveloperSettingsSection() }
            .formStyle(.grouped)
            .frame(width: 460, height: 900)
    }
}
