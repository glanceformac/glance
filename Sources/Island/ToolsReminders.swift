import AppKit
import SwiftUI
import EventKit
import Observation

// MARK: feat/productivity - Apple Reminders via EventKit.
// Permission is requested ONLY when the Reminders sub-tab is opened, never at launch.

struct ReminderItem: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var due: Date?
    var done: Bool
    var listID: String
}

struct ReminderList: Identifiable, Equatable {
    let id: String
    let title: String
    let color: Color
}

@Observable @MainActor
final class RemindersService {
    static let shared = RemindersService()
    enum Access { case notAsked, requesting, granted, denied }
    private(set) var access: Access = .notAsked
    private(set) var lists: [ReminderList] = []
    var selectedList: String?            // nil = all lists
    private(set) var items: [ReminderItem] = []
    private(set) var status = ""

    @ObservationIgnored private var store: EKEventStore?
    @ObservationIgnored private var observer: NSObjectProtocol?
    private var demo: Bool { Env.noPermissions }

    /// Called when the Reminders sub-tab appears.
    func opened() {
        if demo { loadDemo(); return }
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: begin()
        case .notDetermined:
            guard access != .requesting else { return }
            access = .requesting
            let s = EKEventStore()
            store = s
            s.requestFullAccessToReminders { granted, _ in
                Task { @MainActor in
                    if granted { RemindersService.shared.begin() } else { RemindersService.shared.access = .denied }
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
                MainActor.assumeIsolated { RemindersService.shared.reload() }
            }
        }
        reload()
    }

    func reload() {
        if demo { return }
        guard access == .granted, let store else { return }
        lists = store.calendars(for: .reminder).map { ReminderList(id: $0.calendarIdentifier, title: $0.title, color: Color(nsColor: $0.color ?? .systemBlue)) }
        let cals = selectedList.flatMap { id in store.calendars(for: .reminder).filter { $0.calendarIdentifier == id } }
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
        store.fetchReminders(matching: pred) { result in
            // EKReminder is not Sendable: convert to plain values on the callback thread.
            let mapped = (result ?? []).map {
                ReminderItem(id: $0.calendarItemIdentifier, title: $0.title ?? "", due: $0.dueDateComponents?.date, done: $0.isCompleted, listID: $0.calendar.calendarIdentifier)
            }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            Task { @MainActor in
                RemindersService.shared.items = mapped
                RemindersService.shared.status = mapped.isEmpty ? "Nothing to do" : "\(mapped.count) to do"
            }
        }
    }

    func add(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if demo {
            items.insert(ReminderItem(id: UUID().uuidString, title: t, due: nil, done: false, listID: "demo"), at: 0)
            return
        }
        guard access == .granted, let store else { return }
        let r = EKReminder(eventStore: store)
        r.title = t
        let cal = selectedList.flatMap { id in store.calendars(for: .reminder).first { $0.calendarIdentifier == id } } ?? store.defaultCalendarForNewReminders()
        guard let cal else { status = "No Reminders list available"; return }
        r.calendar = cal
        do { try store.save(r, commit: true); reload() } catch { status = "Could not save: \(error.localizedDescription)" }
    }

    func toggle(_ item: ReminderItem) {
        if demo {
            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].done.toggle() }
            return
        }
        guard access == .granted, let store, let r = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        r.isCompleted = !item.done
        do {
            try store.save(r, commit: true)
            // Keep the ticked row visible (struck through) until the next reload, like Reminders does.
            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].done = r.isCompleted }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                self.reload()
            }
        } catch { status = "Could not save: \(error.localizedDescription)" }
    }

    private func loadDemo() {
        access = .granted
        guard items.isEmpty else { return }
        lists = [ReminderList(id: "demo", title: "Reminders", color: .orange), ReminderList(id: "demo2", title: "Work", color: .blue)]
        let cal = Calendar.current
        items = [
            ReminderItem(id: "d1", title: "Call the pharmacy", due: cal.date(byAdding: .hour, value: 3, to: Date()), done: false, listID: "demo"),
            ReminderItem(id: "d2", title: "Send the pilot summary", due: cal.date(byAdding: .day, value: 1, to: Date()), done: false, listID: "demo2"),
            ReminderItem(id: "d3", title: "Book train tickets", due: nil, done: false, listID: "demo"),
            ReminderItem(id: "d4", title: "Renew passport photo", due: nil, done: true, listID: "demo"),
        ]
        status = "Demo data (test mode)"
    }
}

struct RemindersView: View {
    let theme: Theme
    private let svc = RemindersService.shared
    @State private var newTitle = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch svc.access {
            case .denied:
                notice("Reminders access is off", "Allow Glance in System Settings > Privacy & Security > Reminders.", action: ("Open Settings", {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                }))
            case .notAsked, .requesting:
                notice("Waiting for Reminders access", "macOS asks once. Choose Allow Full Access to see and tick your reminders.", action: nil)
            case .granted:
                HStack(spacing: 8) {
                    ToolField(theme: theme, placeholder: "Add a reminder and press Return", text: $newTitle, symbol: "plus.circle.fill", focus: $focused) {
                        svc.add(newTitle); newTitle = ""
                    }
                    Menu {
                        Button("All lists") { svc.selectedList = nil; svc.reload() }
                        Divider()
                        ForEach(svc.lists) { l in Button(l.title) { svc.selectedList = l.id; svc.reload() } }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet").font(.system(size: 10))
                            Text(svc.lists.first { $0.id == svc.selectedList }?.title ?? "All lists").font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }
                        .foregroundStyle(theme.primary).padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(theme.card))
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
                ScrollView {
                    LazyVStack(spacing: 3) {
                        if svc.items.isEmpty {
                            Text("Nothing to do. Add something above.").font(.system(size: 11)).foregroundStyle(theme.tertiary).padding(8)
                        }
                        ForEach(svc.items.sorted { !$0.done && $1.done }) { r in row(r) }
                    }
                }
                Text(svc.status).font(.system(size: 9)).foregroundStyle(theme.tertiary)
            }
        }
        .onAppear { svc.opened() }
        .onDisappear { svc.closed() }
    }

    private func row(_ r: ReminderItem) -> some View {
        let color = svc.lists.first { $0.id == r.listID }?.color ?? theme.accent
        return HStack(spacing: 9) {
            Button { svc.toggle(r) } label: {
                Image(systemName: r.done ? "checkmark.circle.fill" : "circle").font(.system(size: 15))
                    .foregroundStyle(r.done ? color : theme.secondary).contentTransition(.symbolEffect(.replace))
            }.buttonStyle(PressScaleStyle())
            Text(r.title).font(.system(size: 12)).foregroundStyle(r.done ? theme.tertiary : theme.primary)
                .strikethrough(r.done, color: theme.tertiary).lineLimit(1)
            Spacer()
            if let d = r.due {
                Text(d.formatted(.dateTime.weekday(.abbreviated).hour().minute())).font(.system(size: 10))
                    .foregroundStyle(d < Date() && !r.done ? .orange : theme.secondary)
            }
        }
        .padding(.horizontal, 8).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.card))
    }

    private func notice(_ title: String, _ body: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist").font(.system(size: 24)).foregroundStyle(theme.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primary)
            Text(body).font(.system(size: 11)).foregroundStyle(theme.secondary).multilineTextAlignment(.center)
            if let action { ToolPill(theme: theme, title: action.0, prominent: true, action: action.1) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
