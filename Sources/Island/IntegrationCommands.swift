import Foundation

/// Palette commands that connect features from different branches (registered by the integrator).
@MainActor
enum IntegrationCommands {
    static func install() {
        let r = CommandRegistry.shared
        // Tabs added by feat/productivity and feat/system-media.
        r.registerDynamic(id: "integration.tabs") {
            var out: [PaletteCommand] = []
            if AppSettings.shared.prefs.toolsTab {
                out.append(PaletteCommand(id: "tab.Tools", title: "Go to Tools", symbol: "wrench.and.screwdriver",
                                          keywords: ["tools", "utilities"], group: "Go to", priority: 15) { IslandModel.shared.openFromCommand(page: .tools) })
            }
            out.append(PaletteCommand(id: "tab.System", title: "Go to System", symbol: "gauge.with.dots.needle.50percent",
                                      keywords: ["system", "monitor", "cpu", "memory"], group: "Go to", priority: 16) { IslandModel.shared.openFromCommand(page: .system) })
            return out
        }
        // Each tool.
        r.registerDynamic(id: "integration.tools") {
            guard AppSettings.shared.prefs.toolsTab else { return [] }
            return ToolsTab.allCases.enumerated().map { i, t in
                PaletteCommand(id: "tools.\(t.rawValue)", title: "Open \(t.title)", symbol: t.symbol,
                               keywords: ["tools", t.rawValue, t.title], group: "Tools", priority: 40 + i) {
                    IslandModel.shared.openFromCommand(page: .tools)   // opens and keeps the island open
                    ToolsModel.shared.open(t)
                }
            }
        }
        // Quick timer: presets, plus "timer 7" / "7 min timer" typed in the palette.
        let presets: [Double] = [1, 5, 10, 25]
        for m in presets {
            r.register(PaletteCommand(id: "quicktimer.\(Int(m))", title: "Start a \(Int(m)) min timer", symbol: "timer",
                                      keywords: ["timer", "countdown", "\(Int(m))"], group: "Timer", priority: 30) { QuickTimer.shared.start(minutes: m) })
        }
        r.registerProvider(id: "integration.quicktimer") { q in
            let lower = q.lowercased()
            guard lower.contains("timer") || lower.contains("min") else { return [] }
            let digits = lower.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
            guard let m = digits.first, m > 0, m <= 600, !presets.contains(m) else { return [] }
            let label = m == m.rounded() ? "\(Int(m))" : "\(m)"
            return [PaletteCommand(id: "quicktimer.parsed", title: "Start a \(label) min timer", symbol: "timer",
                                   keywords: ["timer", q], group: "Timer", priority: -1) { QuickTimer.shared.start(minutes: m) }]   // q: always matches what was typed
        }
        // Prompter: start the most recent script.
        r.register(PaletteCommand(id: "prompter.latest", title: "Start the Prompter (latest script)", symbol: "text.viewfinder",
                                  keywords: ["prompter", "teleprompter", "read", "script"], group: "Prompter", priority: 55) {
            if !Prompter.shared.startLatest() { IslandModel.shared.openFromCommand(page: .prompter) }
        })
    }
}
