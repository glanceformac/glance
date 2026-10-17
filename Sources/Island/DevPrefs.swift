// MARK: feat/claude-dev
// Preferences for the developer features (Claude usage, long-command islands, notch terminal,
// Homebrew). Kept in one nested struct so Settings.swift only gains a single field.

import Foundation

enum ClaudePlan: String, Codable, CaseIterable, Identifiable {
    case pro, max5, max20
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pro: "Pro"
        case .max5: "Max 5x"
        case .max20: "Max 20x"
        }
    }
    /// Rough starting budgets. Anthropic does not publish token limits and they change, so these
    /// are only a starting point: compare with `/usage` in Claude Code and adjust in Settings.
    /// Tokens = input + output + cache writes (cache reads are not counted).
    var defaults: (sessionTokens: Int, sessionPrompts: Int, weekTokens: Int, weekPrompts: Int) {
        switch self {
        case .pro: (5_000_000, 45, 40_000_000, 300)
        case .max5: (25_000_000, 225, 200_000_000, 1_500)
        case .max20: (100_000_000, 900, 800_000_000, 6_000)
        }
    }
}

enum UsageMetric: String, Codable, CaseIterable, Identifiable {
    case tokens, prompts
    var id: String { rawValue }
    var title: String { self == .tokens ? "Tokens" : "Prompts" }
}

enum DevTab: String, Codable, CaseIterable, Identifiable {
    case claude, terminal, brew
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: "Claude"
        case .terminal: "Terminal"
        case .brew: "Homebrew"
        }
    }
    var symbol: String {
        switch self {
        case .claude: "gauge.with.dots.needle.50percent"
        case .terminal: "terminal"
        case .brew: "mug"
        }
    }
}

struct DevPrefs: Codable, Equatable {
    // Claude usage
    var usageEnabled = true
    var usageCard = false              // Home card (off by default: Home already has five cards)
    var plan: ClaudePlan = .pro      // pick your own plan in Settings › Developer
    /// Kept so older saved settings still decode. No longer changes the plan.
    var planMax20Applied = true
    var metric: UsageMetric = .tokens
    var sessionTokenBudget = ClaudePlan.pro.defaults.sessionTokens
    var sessionPromptBudget = ClaudePlan.pro.defaults.sessionPrompts
    var weekTokenBudget = ClaudePlan.pro.defaults.weekTokens
    var weekPromptBudget = ClaudePlan.pro.defaults.weekPrompts
    var weekResetWeekday = 0           // 0 = rolling 7 days; 1 = Sunday ... 7 = Saturday
    var weekResetHour = 9
    var usagePeeks = true
    // Long-command islands
    var longCommands = true
    var longCommandSeconds = 30
    // Developer page
    var devPage = true
    var lastTab: DevTab = .claude
    var terminalDirectory = ""
    var terminalHistory: [String] = []
    var brewUpgrades = false           // read-only unless turned on

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DevPrefs()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        usageEnabled = v(.usageEnabled, d.usageEnabled)
        usageCard = v(.usageCard, d.usageCard)
        plan = v(.plan, d.plan)
        metric = v(.metric, d.metric)
        sessionTokenBudget = v(.sessionTokenBudget, d.sessionTokenBudget)
        sessionPromptBudget = v(.sessionPromptBudget, d.sessionPromptBudget)
        weekTokenBudget = v(.weekTokenBudget, d.weekTokenBudget)
        weekPromptBudget = v(.weekPromptBudget, d.weekPromptBudget)
        weekResetWeekday = v(.weekResetWeekday, d.weekResetWeekday)
        weekResetHour = v(.weekResetHour, d.weekResetHour)
        usagePeeks = v(.usagePeeks, d.usagePeeks)
        longCommands = v(.longCommands, d.longCommands)
        longCommandSeconds = v(.longCommandSeconds, d.longCommandSeconds)
        devPage = v(.devPage, d.devPage)
        lastTab = v(.lastTab, d.lastTab)
        terminalDirectory = v(.terminalDirectory, d.terminalDirectory)
        terminalHistory = v(.terminalHistory, d.terminalHistory)
        brewUpgrades = v(.brewUpgrades, d.brewUpgrades)
        planMax20Applied = v(.planMax20Applied, true)
    }

    mutating func applyPlanDefaults() {
        let d = plan.defaults
        sessionTokenBudget = d.sessionTokens
        sessionPromptBudget = d.sessionPrompts
        weekTokenBudget = d.weekTokens
        weekPromptBudget = d.weekPrompts
    }
}
