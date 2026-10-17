import AppKit
import SwiftUI

// MARK: - Football card (Home): the team picked in Settings › Football

struct FootballCard: View {
    let theme: Theme
    private let svc = FootballService.shared
    private let prefs = AppSettings.shared.prefs

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let team = svc.team {
                    Badge(team: team, size: 14)
                    Text(team.name.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(Color(nsColor: team.displayColor)).lineLimit(1)
                } else {
                    Text("FOOTBALL").font(.system(size: 9, weight: .heavy)).foregroundStyle(theme.secondary)
                }
                Spacer(minLength: 0)
                if let pos = svc.standing?.split(separator: " ").first {
                    Text(String(pos)).font(.system(size: 9, weight: .bold)).foregroundStyle(theme.secondary).help(svc.standing ?? "")
                }
            }
            if let live = svc.live, live.isLive || live.statusName == "STATUS_HALFTIME" {
                Text(prefs.spoilerFree ? "LIVE · score hidden" : "LIVE \(live.clock)")
                    .font(.system(size: 9, weight: .heavy)).foregroundStyle(.red)
                matchRow(live, showScore: !prefs.spoilerFree)
            } else if let n = svc.next {
                matchRow(n, showScore: false)
                Text(n.date.formatted(.dateTime.weekday(.abbreviated).day().hour().minute()))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.primary).lineLimit(1)
                Text(countdown(to: n.date)).font(.system(size: 9)).foregroundStyle(theme.secondary).lineLimit(1)
            } else {
                Text(svc.team == nil ? "Pick a team in Settings › Football" : (svc.standing == nil ? "Loading fixtures…" : "No upcoming match")).font(.system(size: 10)).foregroundStyle(theme.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if let l = svc.last, !(prefs.spoilerFree && svc.finishedUnwatched != nil) {
                    Text("\(l.resultLetter) \(l.teamScore)–\(l.opponentScore) \(l.opponent.abbr)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(l.resultLetter == "W" ? Color.green : (l.resultLetter == "L" ? Color.red : theme.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { FootballService.shared.watchReplay() } label: {
                    Image(systemName: "play.circle.fill").font(.system(size: 15)).foregroundStyle(Color(nsColor: svc.team?.displayColor ?? .systemBlue))
                }
                .buttonStyle(PressScaleStyle())
                .help(svc.finishedUnwatched != nil ? "Watch the replay" : "Replay goal")
            }
        }
    }

    private func matchRow(_ m: MatchInfo, showScore: Bool) -> some View {
        HStack(spacing: 4) {
            Badge(team: m.opponent, size: 18)
            Text(showScore ? "\(m.teamScore)–\(m.opponentScore)" : (m.teamHome ? "v \(m.opponent.abbr)" : "@ \(m.opponent.abbr)"))
                .font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(theme.primary).lineLimit(1)
        }
        .help("\(m.leagueName): \(m.home.name) v \(m.away.name)")
    }

    private func countdown(to d: Date) -> String {
        let s = Int(d.timeIntervalSinceNow)
        if s <= 0 { return "Kick-off soon" }
        let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        return days > 0 ? "in \(days)d \(h)h" : (h > 0 ? "in \(h)h \(m)m" : "in \(m)m")
    }
}

// MARK: - Today tab: the daily scoreboard

struct TodayView: View {
    let theme: Theme
    private let store = TodoStore.shared
    @State private var newTask = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Scoreboard header.
            HStack(spacing: 10) {
                Text("YOU").font(.system(size: 13, weight: .heavy)).foregroundStyle(theme.primary)
                scoreBox("\(store.doneToday)")
                Text("–").font(.system(size: 16, weight: .heavy)).foregroundStyle(theme.secondary)
                scoreBox("\(store.left)")
                Text("TO-DO").font(.system(size: 13, weight: .heavy)).foregroundStyle(theme.secondary)
                Spacer()
                if AppSettings.shared.prefs.focusMatch {
                    Label(FocusMatch.shared.scoreLine, systemImage: "sportscourt")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.secondary)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill").foregroundStyle(theme.accent)
                TextField("Add a task and press Return", text: $newTask)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(theme.primary)
                    .focused($focused)
                    .onSubmit { store.add(newTask); newTask = "" }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(focused ? theme.accent.opacity(0.8) : .clear, lineWidth: 1.2))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if store.items.isEmpty {
                        Text("Nothing on the list. Each task you tick is a goal.").font(.system(size: 11)).foregroundStyle(theme.tertiary).padding(8)
                    }
                    ForEach(store.items.sorted { !$0.done && $1.done }) { item in
                        TodoRow(item: item, theme: theme)
                    }
                }
            }
            Text("Full-time whistle at \(AppSettings.shared.prefs.endOfDayHour):00 · done tasks clear at midnight")
                .font(.system(size: 10)).foregroundStyle(theme.tertiary)
        }
        .padding(.bottom, 12)
    }

    private func scoreBox(_ s: String) -> some View {
        Text(s).font(.system(size: 18, weight: .heavy).monospacedDigit()).foregroundStyle(.white)
            .frame(minWidth: 26, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.14)))
            .contentTransition(.numericText())
    }
}

struct TodoRow: View {
    let item: TodoItem
    let theme: Theme
    @State private var hover = false
    var body: some View {
        HStack(spacing: 9) {
            Button { TodoStore.shared.toggle(item) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15)).foregroundStyle(item.done ? theme.accent : theme.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressScaleStyle())
            Text(item.title).font(.system(size: 12)).foregroundStyle(item.done ? theme.tertiary : theme.primary)
                .strikethrough(item.done, color: theme.tertiary).lineLimit(1)
            Spacer()
            if hover {
                Button { TodoStore.shared.delete(item) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.card.opacity(hover ? 1.3 : 0)))
        .onHover { hover = $0 }
    }
}
