// MARK: feat/claude-dev
// Claude usage UI: Home card, Developer page tab, and the Settings section.

import AppKit
import SwiftUI

private func usageColor(_ f: Double, theme: Theme) -> Color {
    if f >= 0.95 { return Color(red: 1, green: 0.35, blue: 0.3) }
    if f >= 0.80 { return .orange }
    return theme.accent
}

/// Thin progress bar with an optional projection tick.
struct UsageBar: View {
    let fraction: Double
    var projected: Double? = nil
    let theme: Theme
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { g in
            let f = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(theme.tertiary.opacity(0.45))
                if let p = projected, p > f {
                    Capsule().fill(usageColor(p, theme: theme).opacity(0.28)).frame(width: g.size.width * min(p, 1))
                }
                Capsule().fill(usageColor(fraction, theme: theme)).frame(width: max(height, g.size.width * f))
            }
        }
        .frame(height: height)
    }
}

// MARK: Home card

struct ClaudeUsageCard: View {
    let theme: Theme
    private let usage = ClaudeUsage.shared

    var body: some View {
        let s = usage.snapshot.session, w = usage.snapshot.week
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "sparkle").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                Text("Claude").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.primary)
                Spacer(minLength: 0)
                Text("est.").font(.system(size: 9, weight: .medium)).foregroundStyle(theme.tertiary)
            }
            Spacer(minLength: 2)
            Text(s.active ? "\(Int((s.fraction * 100).rounded()))%" : "–")
                .font(.system(size: 28, weight: .light).monospacedDigit()).foregroundStyle(theme.primary)
                .contentTransition(.numericText())
            Text(s.active ? "session · resets \(ClaudeUsage.short((s.end ?? 0) - Date().timeIntervalSince1970))" : "no session running")
                .font(.system(size: 10)).foregroundStyle(theme.secondary).lineLimit(1)
            Spacer(minLength: 4)
            UsageBar(fraction: s.fraction, projected: s.projected, theme: theme, height: 4)
            Spacer(minLength: 5)
            HStack(spacing: 4) {
                Text("Week").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.secondary)
                UsageBar(fraction: w.fraction, theme: theme, height: 3)
                Text("\(Int((w.fraction * 100).rounded()))%").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(theme.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { DevPage.open(.claude) }
        .help("Estimated Claude Code usage. Click for details.")
        .onAppear { usage.setVisible("card", true) }
        .onDisappear { usage.setVisible("card", false) }
    }
}

// MARK: Developer page tab

struct ClaudeUsagePane: View {
    let theme: Theme
    private let usage = ClaudeUsage.shared

    var body: some View {
        let snap = usage.snapshot
        VStack(spacing: 10) {
            if !AppSettings.shared.prefs.dev.usageEnabled {
                Text("Claude usage is turned off in Settings › Developer.")
                    .font(.system(size: 12)).foregroundStyle(theme.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 10) {
                    windowCard(title: "5-hour session", w: snap.session, budget: sessionBudget,
                               empty: "No session running. A new one starts with your next prompt.")
                    windowCard(title: AppSettings.shared.prefs.dev.weekResetWeekday == 0 ? "Last 7 days" : "This week",
                               w: snap.week, budget: weekBudget, empty: "")
                }
                .frame(height: 128)
                statsTable(snap)
                HStack(spacing: 6) {
                    if usage.scanning { ProgressView().controlSize(.mini) }
                    Text(footer).font(.system(size: 10)).foregroundStyle(theme.tertiary).lineLimit(1)
                    Spacer()
                    Button("Refresh") { usage.refresh() }.buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.secondary)
                        .disabled(usage.scanning)
                }
                .frame(height: 14)
            }
        }
        .onAppear { usage.setVisible("pane", true) }
        .onDisappear { usage.setVisible("pane", false) }
    }

    private var sessionBudget: String {
        let d = AppSettings.shared.prefs.dev
        return d.metric == .tokens ? "\(ClaudeUsage.tokens(d.sessionTokenBudget)) tokens" : "\(d.sessionPromptBudget) prompts"
    }
    private var weekBudget: String {
        let d = AppSettings.shared.prefs.dev
        return d.metric == .tokens ? "\(ClaudeUsage.tokens(d.weekTokenBudget)) tokens" : "\(d.weekPromptBudget) prompts"
    }

    private var footer: String {
        let plan = AppSettings.shared.prefs.dev.plan.title
        let when = usage.lastUpdated.map { "updated \($0.formatted(date: .omitted, time: .shortened))" } ?? usage.status
        return "\(plan) plan · percentages are estimates against your budgets in Settings · \(when)"
    }

    private func windowCard(title: String, w: UsageWindow, budget: String, empty: String) -> some View {
        let now = Date().timeIntervalSince1970
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(theme.secondary)
                Spacer()
                if let end = w.end, w.active {
                    Text("resets in \(ClaudeUsage.short(end - now))").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.secondary)
                } else if w.active {
                    Text("rolling").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.tertiary)
                }
            }
            if w.active {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int((w.fraction * 100).rounded()))%")
                        .font(.system(size: 30, weight: .light).monospacedDigit()).foregroundStyle(theme.primary)
                        .contentTransition(.numericText())
                    Text("of \(budget) (est.)").font(.system(size: 10)).foregroundStyle(theme.secondary).lineLimit(1)
                }
                UsageBar(fraction: w.fraction, projected: w.projected, theme: theme, height: 6)
                if let p = w.projected {
                    Text(p >= 1 ? "On pace to reach the limit before reset (about \(Int((p * 100).rounded()))%)"
                                : "On pace for about \(Int((p * 100).rounded()))% by reset")
                        .font(.system(size: 10)).foregroundStyle(p >= 1 ? usageColor(1, theme: theme) : theme.secondary).lineLimit(1)
                } else {
                    Text(w.end == nil ? "No projection for a rolling window" : "Projection after 10 minutes of use")
                        .font(.system(size: 10)).foregroundStyle(theme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("\(ClaudeUsage.tokens(w.totals.counted)) tokens · \(w.totals.prompts) prompts · \(ClaudeUsage.dollars(w.totals.cost))")
                    .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(theme.secondary).lineLimit(1)
            } else {
                Spacer(minLength: 0)
                Text(empty).font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.cardStroke, lineWidth: 0.5))
    }

    private func statsTable(_ s: UsageSnapshot) -> some View {
        let cols: [(String, UsageTotals)] = [("Session", s.session.totals), ("Week", s.week.totals), ("Today", s.today)]
        return VStack(spacing: 3) {
            HStack(spacing: 0) {
                cell("", bold: true, align: .leading)
                ForEach(["Input", "Output", "Cache write", "Cache read", "Prompts", "API calls", "API cost"], id: \.self) { cell($0, bold: true) }
            }
            ForEach(cols, id: \.0) { name, t in
                HStack(spacing: 0) {
                    cell(name, bold: true, align: .leading)
                    cell(ClaudeUsage.tokens(t.input)); cell(ClaudeUsage.tokens(t.output))
                    cell(ClaudeUsage.tokens(t.cacheWrite)); cell(ClaudeUsage.tokens(t.cacheRead))
                    cell(t.prompts.formatted(.number.locale(Locale(identifier: "en_GB")))); cell(t.calls.formatted(.number.locale(Locale(identifier: "en_GB")))); cell(ClaudeUsage.dollars(t.cost))
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.card))
        .help("API cost is what these tokens would cost at Anthropic's API list prices; a subscription is billed differently.")
    }

    private func cell(_ s: String, bold: Bool = false, align: Alignment = .trailing) -> some View {
        Text(s).font(.system(size: 10.5, weight: bold ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(bold ? theme.secondary : theme.primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: align)
    }
}

// MARK: Settings section (referenced by one line in SettingsView)

struct DeveloperSettingsSection: View {
    @Bindable private var settings = AppSettings.shared
    private let usage = ClaudeUsage.shared

    var body: some View {
        Section("Developer") {
            Toggle("Developer page in the island (Claude, Terminal, Homebrew)", isOn: $settings.prefs.dev.devPage)
            Toggle("Track Claude Code usage", isOn: $settings.prefs.dev.usageEnabled)
            if settings.prefs.dev.usageEnabled {
                Toggle("Show the Claude card on Home", isOn: $settings.prefs.dev.usageCard)
                Toggle("Peek at 80% and 95%", isOn: $settings.prefs.dev.usagePeeks)
                Picker("Plan", selection: Binding(get: { settings.prefs.dev.plan }, set: { p in
                    settings.prefs.dev.plan = p
                    settings.prefs.dev.applyPlanDefaults()
                })) {
                    ForEach(ClaudePlan.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Measure by", selection: $settings.prefs.dev.metric) {
                    ForEach(UsageMetric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                budgetField("5-hour token budget", value: $settings.prefs.dev.sessionTokenBudget)
                budgetField("5-hour prompt budget", value: $settings.prefs.dev.sessionPromptBudget)
                budgetField("Weekly token budget", value: $settings.prefs.dev.weekTokenBudget)
                budgetField("Weekly prompt budget", value: $settings.prefs.dev.weekPromptBudget)
                Picker("Week resets", selection: $settings.prefs.dev.weekResetWeekday) {
                    Text("Rolling 7 days").tag(0)
                    ForEach(1...7, id: \.self) { d in Text(Calendar.current.weekdaySymbols[d - 1]).tag(d) }
                }
                if settings.prefs.dev.weekResetWeekday != 0 {
                    Stepper("at \(String(format: "%02d:00", settings.prefs.dev.weekResetHour))",
                            value: $settings.prefs.dev.weekResetHour, in: 0...23)
                }
                HStack {
                    Button("Use \(settings.prefs.dev.plan.title) defaults") { settings.prefs.dev.applyPlanDefaults() }
                    Spacer()
                    if usage.snapshot.session.active {
                        Text("Session now: \(ClaudeUsage.tokens(usage.snapshot.session.totals.counted)) tokens, \(usage.snapshot.session.totals.prompts) prompts")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Claude plan limits are not stored on this Mac, so every percentage is an estimate against these budgets. Tokens count input, output and cache writes (cache reads are left out). Compare with /usage in Claude Code and adjust. Glance reads only ~/.claude/projects transcripts (numbers only), never your login or keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Long-command islands (Claude Code Bash)", isOn: $settings.prefs.dev.longCommands)
            if settings.prefs.dev.longCommands {
                Stepper("Show after \(settings.prefs.dev.longCommandSeconds) s", value: $settings.prefs.dev.longCommandSeconds, in: 5...600, step: 5)
                Text("Needs the PreToolUse hook from INSTALL-HOOKS.md.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Allow Homebrew upgrades from the island", isOn: $settings.prefs.dev.brewUpgrades)
            Text("Off: the Homebrew tab only lists outdated packages. On: each upgrade still asks you to confirm.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { usage.setVisible("settings", true) }
        .onDisappear { usage.setVisible("settings", false) }
    }

    private func budgetField(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            // Fixed en_GB grouping (100,000,000), not the Mac region (en_IN showed 10,00,00,000).
            TextField("", value: value, format: .number.locale(Locale(identifier: "en_GB")))
                .multilineTextAlignment(.trailing)
                .frame(width: 130)
        }
    }
}
