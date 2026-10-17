import AppKit
import SwiftUI
import EventKit
import Observation

// MARK: feat/productivity - Month calendar (EventKit; same Calendar permission Glance already uses)

struct MonthEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: Color
    let joinURL: URL?
    let calendar: String
}

@Observable @MainActor
final class MonthCalendarService {
    static let shared = MonthCalendarService()
    enum Access { case unknown, granted, denied }
    private(set) var access: Access = .unknown
    var month: Date = Calendar.current.startOfMonth(for: Date())
    var selected: Date = Calendar.current.startOfDay(for: Date())
    private(set) var events: [Date: [MonthEvent]] = [:]   // key: start of day

    @ObservationIgnored private var store: EKEventStore?
    @ObservationIgnored private var observer: NSObjectProtocol?

    func opened() {
        if Env.noPermissions { access = .granted; loadDemo(); return }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: begin()
        case .notDetermined:
            let s = EKEventStore()
            store = s
            s.requestFullAccessToEvents { granted, _ in
                Task { @MainActor in
                    if granted { MonthCalendarService.shared.begin() } else { MonthCalendarService.shared.access = .denied }
                }
            }
        default: access = .denied
        }
    }

    func closed() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
    }

    private func begin() {
        access = .granted
        if store == nil { store = EKEventStore() }
        if observer == nil, let store {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
                MainActor.assumeIsolated { MonthCalendarService.shared.reload() }
            }
        }
        reload()
    }

    /// First day shown in the grid (a full-week-aligned 6 x 7 grid).
    var gridStart: Date {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: month)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        return cal.date(byAdding: .day, value: -lead, to: month)!
    }

    func shift(_ months: Int) {
        month = Calendar.current.date(byAdding: .month, value: months, to: month)!
        reload()
    }

    func goToday() {
        month = Calendar.current.startOfMonth(for: Date())
        selected = Calendar.current.startOfDay(for: Date())
        reload()
    }

    func reload() {
        if Env.noPermissions { loadDemo(); return }
        guard access == .granted, let store else { return }
        let cal = Calendar.current
        let start = gridStart
        let end = cal.date(byAdding: .day, value: 42, to: start)!
        let found = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        var map: [Date: [MonthEvent]] = [:]
        for e in found {
            let ev = MonthEvent(id: (e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)", title: e.title ?? "Event",
                                start: e.startDate, end: endD0(e), allDay: e.isAllDay,
                                color: Color(nsColor: e.calendar?.color ?? .systemBlue), joinURL: MeetingLinks.joinURL(for: e), calendar: e.calendar?.title ?? "")
            // Spread multi-day events over each day they touch (all-day end dates are exclusive).
            var day = cal.startOfDay(for: e.startDate)
            let endD: Date = e.endDate ?? e.startDate
            let last = e.isAllDay ? endD.addingTimeInterval(-1) : endD
            var guardCount = 0
            while day <= last, guardCount < 45 {
                if day >= start && day < end { map[day, default: []].append(ev) }
                day = cal.date(byAdding: .day, value: 1, to: day)!
                guardCount += 1
            }
        }
        for k in map.keys { map[k]?.sort { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) } }
        events = map
    }

    private func loadDemo() {
        let cal = Calendar.current
        let start = gridStart
        var map: [Date: [MonthEvent]] = [:]
        let today = cal.startOfDay(for: Date())
        func ev(_ title: String, _ dayOffset: Int, _ hour: Int, _ colour: Color, join: Bool = false, allDay: Bool = false) {
            let day = cal.date(byAdding: .day, value: dayOffset, to: today)!
            let s = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
            map[day, default: []].append(MonthEvent(id: "\(title)\(dayOffset)", title: title, start: s, end: s.addingTimeInterval(3600), allDay: allDay, color: colour,
                                                    joinURL: join ? URL(string: "https://meet.google.com/abc-defg-hij") : nil, calendar: "Work"))
        }
        ev("Ward handover review", 0, 9, .blue, join: true)
        ev("Lunch with Sam", 0, 13, .green)
        ev("Pilot results call", 0, 16, .purple, join: true)
        ev("Design review", 1, 10, .blue)
        ev("Dentist", 3, 15, .orange)
        ev("Anthropic meetup", 5, 18, .pink)
        ev("Bank holiday", 7, 0, .red, allDay: true)
        ev("Glance release", -4, 11, .blue)
        ev("Team stand-up", -2, 9, .teal)
        ev("Visa check-in", 9, 14, .orange)
        events = map.filter { $0.key >= start }
    }
}

private func endD0(_ e: EKEvent) -> Date { e.endDate ?? e.startDate }

extension Calendar {
    func startOfMonth(for d: Date) -> Date { self.date(from: dateComponents([.year, .month], from: d))! }
}

struct MonthCalendarView: View {
    let theme: Theme
    private let svc = MonthCalendarService.shared
    private let cal = Calendar.current

    var body: some View {
        Group {
            if svc.access == .denied {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 24)).foregroundStyle(theme.tertiary)
                    Text("Calendar access is off").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primary)
                    Text("Allow Glance in System Settings > Privacy & Security > Calendars.").font(.system(size: 11)).foregroundStyle(theme.secondary)
                    ToolPill(theme: theme, title: "Open Settings", prominent: true) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    grid.frame(width: 300)
                    dayList.frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { svc.opened() }
        .onDisappear { svc.closed() }
    }

    private var grid: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(svc.month.formatted(.dateTime.month(.wide).year())).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primary)
                Spacer()
                nav("chevron.left") { svc.shift(-1) }
                ToolPill(theme: theme, title: "Today") { withAnimation(.easeOut(duration: 0.15)) { svc.goToday() } }
                nav("chevron.right") { svc.shift(1) }
            }
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    let idx = (cal.firstWeekday - 1 + i) % 7
                    Text(cal.veryShortWeekdaySymbols[idx]).font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.tertiary).frame(maxWidth: .infinity)
                }
            }
            let start = svc.gridStart
            VStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<7, id: \.self) { col in
                            cell(cal.date(byAdding: .day, value: row * 7 + col, to: start)!)
                        }
                    }
                }
            }
        }
    }

    private func nav(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.primary)
                .frame(width: 24, height: 24).background(Circle().fill(theme.card))
        }.buttonStyle(PressScaleStyle())
    }

    private func cell(_ day: Date) -> some View {
        let inMonth = cal.isDate(day, equalTo: svc.month, toGranularity: .month)
        let today = cal.isDateInToday(day)
        let selected = cal.isDate(day, inSameDayAs: svc.selected)
        let evs = svc.events[cal.startOfDay(for: day)] ?? []
        return Button { withAnimation(.easeOut(duration: 0.12)) { svc.selected = cal.startOfDay(for: day) } } label: {
            VStack(spacing: 1) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 11, weight: today ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(today ? theme.onAccent : (inMonth ? theme.primary : theme.tertiary))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(today ? theme.accent : .clear))
                HStack(spacing: 2) {
                    ForEach(Array(evs.prefix(3).enumerated()), id: \.offset) { _, e in Circle().fill(e.color).frame(width: 4, height: 4) }
                }.frame(height: 4)
            }
            .frame(maxWidth: .infinity).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? theme.accent.opacity(0.22) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? theme.accent.opacity(0.6) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + (evs.isEmpty ? "" : ", \(evs.count) events"))
    }

    private var dayList: some View {
        let evs = svc.events[cal.startOfDay(for: svc.selected)] ?? []
        return VStack(alignment: .leading, spacing: 6) {
            Text(svc.selected.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primary)
            ScrollView {
                LazyVStack(spacing: 4) {
                    if evs.isEmpty {
                        Text("No events").font(.system(size: 11)).foregroundStyle(theme.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                    ForEach(evs) { e in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 1.5).fill(e.color).frame(width: 3, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.primary).lineLimit(1)
                                Text(e.allDay ? "All day" : "\(e.start.formatted(date: .omitted, time: .shortened)) to \(e.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.system(size: 10)).foregroundStyle(theme.secondary)
                            }
                            Spacer(minLength: 4)
                            if let url = e.joinURL {
                                ToolPill(theme: theme, title: "Join", symbol: "video.fill", prominent: true) {
                                    NSWorkspace.shared.open(url)
                                    IslandModel.shared.setExpanded(false)
                                }
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.card))
                    }
                }
            }
        }
    }
}
