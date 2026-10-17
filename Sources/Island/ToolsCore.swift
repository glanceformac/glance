import AppKit
import SwiftUI
import Observation

// MARK: feat/productivity
// The Tools tab: ten compact sub-tabs in the expanded island. Each tool lives in its own
// Tools*.swift file. Nothing here runs until the tab is opened (no timers, no observers).
//
// Hook for the integrator: when a CommandRegistry exists on main, register one command per
// ToolsTab, e.g. `Command("Tools: Calculator") { ToolsModel.shared.open(.calc) }`, plus
// "Tools: Start 5 minute timer" -> QuickTimer.shared.start(minutes: 5). See ToolsModel.open(_:).

enum ToolsTab: String, CaseIterable, Identifiable, Codable {
    case calc, emoji, notes, reminders, calendar, apps, search, translate, shortcuts, focus, timer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .calc: "Calculator"
        case .emoji: "Emoji"
        case .notes: "Notes"
        case .reminders: "Reminders"
        case .calendar: "Calendar"
        case .apps: "Apps"
        case .search: "Search"
        case .translate: "Translate"
        case .shortcuts: "Shortcuts"
        case .focus: "Focus"
        case .timer: "Timer"
        }
    }
    var symbol: String {
        switch self {
        case .calc: "plus.forwardslash.minus"
        case .emoji: "face.smiling"
        case .notes: "note.text"
        case .reminders: "checklist"
        case .calendar: "calendar"
        case .apps: "square.grid.3x3"
        case .search: "magnifyingglass"
        case .translate: "character.bubble"
        case .shortcuts: "bolt.horizontal"
        case .focus: "moon"
        case .timer: "timer"
        }
    }
}

/// View state kept outside the views so tests can drive it.
@Observable @MainActor
final class ToolsViewState {
    static let shared = ToolsViewState()
    var emojiQuery = ""
    var appQuery = ""
}

@Observable @MainActor
final class ToolsModel {
    static let shared = ToolsModel()
    var tab: ToolsTab = .calc

    /// Opens the island on a given tool (used by the debug channel and, later, the command palette).
    func open(_ t: ToolsTab) {
        let m = IslandModel.shared
        tab = t
        withAnimation(IslandModel.openSpring) { m.page = .tools }
        if !m.expanded { m.setExpanded(true) }
    }
}

// MARK: - Storage (Application Support, owner-only permissions)

@MainActor
enum ToolsStore {
    /// Real app: ~/Library/Application Support/Glance/Tools. Isolated test instance: next to its socket,
    /// so a test run never reads or writes your real notes.
    static var directory: URL {
        let base = ClaudeServer.directory.appendingPathComponent("Tools", isDirectory: true)   // isolated: Env.supportDir
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        chmod(base.path, 0o700)
        return base
    }

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Atomic write with 0600 permissions, off the main thread.
    nonisolated static func write(_ data: Data, to url: URL) {
        DispatchQueue.global(qos: .utility).async {
            let tmp = url.appendingPathExtension("tmp")
            guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
            chmod(url.path, 0o600)
        }
    }

    static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let d = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}

/// Small persisted preferences for the Tools (kept out of the main Prefs blob).
struct ToolsPrefsData: Codable, Equatable {
    var favouriteApps: [String] = []          // bundle identifiers
    var searchEngine = "google"
    var recentEmoji: [String] = []
    var translateTarget = "en"
    var translateSource = "auto"
    var breakReminderMinutes = 0               // 0 = off
    var noiseKind = "brown"
    var noiseVolume = 0.35
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ToolsPrefsData()
        favouriteApps = (try? c.decodeIfPresent([String].self, forKey: .favouriteApps)) ?? d.favouriteApps
        searchEngine = (try? c.decodeIfPresent(String.self, forKey: .searchEngine)) ?? d.searchEngine
        recentEmoji = (try? c.decodeIfPresent([String].self, forKey: .recentEmoji)) ?? d.recentEmoji
        translateTarget = (try? c.decodeIfPresent(String.self, forKey: .translateTarget)) ?? d.translateTarget
        translateSource = (try? c.decodeIfPresent(String.self, forKey: .translateSource)) ?? d.translateSource
        breakReminderMinutes = (try? c.decodeIfPresent(Int.self, forKey: .breakReminderMinutes)) ?? d.breakReminderMinutes
        noiseKind = (try? c.decodeIfPresent(String.self, forKey: .noiseKind)) ?? d.noiseKind
        noiseVolume = (try? c.decodeIfPresent(Double.self, forKey: .noiseVolume)) ?? d.noiseVolume
    }
}

@Observable @MainActor
final class ToolsPrefs {
    static let shared = ToolsPrefs()
    var data: ToolsPrefsData {
        didSet {
            guard data != oldValue, let d = try? JSONEncoder().encode(data) else { return }
            ToolsStore.write(d, to: ToolsStore.url("prefs.json"))
        }
    }
    private init() { data = ToolsStore.read(ToolsPrefsData.self, "prefs.json") ?? ToolsPrefsData() }
}

// MARK: - Shared small views

struct ToolField: View {
    let theme: Theme
    let placeholder: String
    @Binding var text: String
    var symbol = "magnifyingglass"
    var focus: FocusState<Bool>.Binding?
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(theme.secondary)
            field
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.tertiary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder((focus?.wrappedValue ?? false) ? theme.accent.opacity(0.8) : .clear, lineWidth: 1.2))
    }

    @ViewBuilder private var field: some View {
        let tf = TextField(placeholder, text: $text)
            .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(theme.primary)
            .onSubmit(onSubmit)
        if let focus { tf.focused(focus) } else { tf }
    }
}

struct ToolPill: View {
    let theme: Theme
    let title: String
    var symbol: String? = nil
    var selected = false
    var prominent = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .medium)) }
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(prominent ? theme.onAccent : (selected ? theme.primary : theme.primary.opacity(0.85)))
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(prominent ? theme.accent : (selected ? theme.accent.opacity(theme.dark ? 0.26 : 0.16) : theme.card.opacity(hover ? 1.8 : 1))))
            .overlay(Capsule().strokeBorder(selected ? theme.accent.opacity(0.5) : theme.cardStroke, lineWidth: 0.5))
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hover = $0 }
    }
}

// MARK: - The page

struct ToolsPage: View {
    let theme: Theme
    private let tools = ToolsModel.shared

    var body: some View {
        VStack(spacing: 8) {
            ToolsTabBar(theme: theme)
            Group {
                switch tools.tab {
                case .calc: CalculatorView(theme: theme)
                case .emoji: EmojiView(theme: theme)
                case .notes: NotesView(theme: theme)
                case .reminders: RemindersView(theme: theme)
                case .calendar: MonthCalendarView(theme: theme)
                case .apps: AppLauncherView(theme: theme)
                case .search: WebSearchView(theme: theme)
                case .translate: TranslateView(theme: theme)
                case .shortcuts: ShortcutsRunnerView(theme: theme)
                case .focus: FocusSwitcherView(theme: theme)
                case .timer: TimerExtrasView(theme: theme)
                }
            }
            .id(tools.tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.opacity)
        }
        .padding(.bottom, 14)
    }
}

struct ToolsTabBar: View {
    let theme: Theme
    private let tools = ToolsModel.shared
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 1) {
            ForEach(ToolsTab.allCases) { t in
                let selected = tools.tab == t
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tools.tab = t }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: t.symbol).font(.system(size: 11, weight: .medium))
                        if selected { Text(t.title).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize() }
                    }
                    .foregroundStyle(selected ? theme.primary : theme.secondary)
                    .padding(.horizontal, selected ? 10 : 8).frame(height: 24)
                    .background {
                        if selected {
                            Capsule().fill(theme.accent.opacity(theme.dark ? 0.26 : 0.16))
                                .overlay(Capsule().strokeBorder(theme.accent.opacity(0.45), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "toolstab", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(t.title)
                .accessibilityLabel(t.title)
            }
        }
        .padding(2)
        .background(Capsule().fill(theme.card.opacity(0.6)))
    }
}

// MARK: - Settings section

struct ToolsSettingsSection: View {
    @Bindable private var settings = AppSettings.shared
    @State private var breakMinutes = ToolsPrefs.shared.data.breakReminderMinutes

    var body: some View {
        Section("Tools") {
            Toggle("Show the Tools tab", isOn: $settings.prefs.toolsTab)
            Picker("Break reminder", selection: Binding(get: { breakMinutes }, set: {
                breakMinutes = $0
                ToolsPrefs.shared.data.breakReminderMinutes = $0
                BreakReminder.shared.apply(minutes: $0)
            })) {
                Text("Off").tag(0)
                ForEach([20, 30, 45, 60], id: \.self) { Text("Every \($0) min").tag($0) }
            }
            Text("Reminders and Calendar permissions are requested only when you open those tools. Notes and rates are stored in Application Support, readable only by you. Translation runs on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
