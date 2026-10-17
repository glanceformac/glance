import AppKit
import SwiftUI
import Observation

// MARK: - Live Activities
//
// Small satellite capsules that sit BESIDE the closed pill for things that run alongside whatever
// the pill is already showing (focus timer, keep-awake, a live match, a Claude run, a long
// command). They never change the pill's size or shape.
//
// API for other features:
//     ActivityCenter.start(id: "keepawake", symbol: "cup.and.saucer.fill", text: "Awake", tint: .orange)
//     ActivityCenter.update(id: "keepawake", text: "Awake 1h")
//     ActivityCenter.end(id: "keepawake")
// A countdown is just `endDate:` (the capsule counts down by itself, no per-second work from you).

struct LiveActivity: Identifiable, Equatable {
    var id: String
    var symbol: String
    var text: String
    var tint: Color = .white
    /// Counts down to this date (replaces `text` in the capsule when set).
    var endDate: Date? = nil
    /// Counts up from this date (e.g. a Claude run).
    var startDate: Date? = nil
    /// Pulse the symbol gently (Core Animation driven, no SwiftUI invalidation).
    var pulsing = false
}

@Observable @MainActor
final class ActivityCenter {
    static let shared = ActivityCenter()
    /// In order of arrival.
    private(set) var activities: [LiveActivity] = []
    /// Most capsules shown at once (two each side of the pill).
    static let maxVisible = 4

    var visible: [LiveActivity] { Array(activities.prefix(Self.maxVisible)) }

    static func start(_ a: LiveActivity) { shared.upsert(a) }

    /// `ttl`: end the capsule by itself if nobody updates it for that long (a crashed script must not leave it stuck).
    static func start(id: String, symbol: String, text: String, tint: Color = .white,
                      endDate: Date? = nil, startDate: Date? = nil, pulsing: Bool = false, ttl: TimeInterval? = nil) {
        shared.upsert(LiveActivity(id: id, symbol: symbol, text: text, tint: tint, endDate: endDate, startDate: startDate, pulsing: pulsing))
        if let ttl { shared.armTTL(id, ttl) }
    }

    /// Keep an activity alive (resets its ttl).
    static func touch(id: String, ttl: TimeInterval) { if shared.activities.contains(where: { $0.id == id }) { shared.armTTL(id, ttl) } }

    @ObservationIgnored private var ttlTasks: [String: Task<Void, Never>] = [:]
    fileprivate func armTTL(_ id: String, _ ttl: TimeInterval) {
        ttlTasks[id]?.cancel()
        ttlTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ttl))
            guard !Task.isCancelled else { return }
            self?.remove(id)
        }
    }

    static func update(id: String, symbol: String? = nil, text: String? = nil, tint: Color? = nil, endDate: Date? = nil) {
        guard var a = shared.activities.first(where: { $0.id == id }) else { return }
        if let symbol { a.symbol = symbol }
        if let text { a.text = text }
        if let tint { a.tint = tint }
        if let endDate { a.endDate = endDate }
        shared.upsert(a)
    }

    static func end(id: String) { shared.remove(id) }

    private func upsert(_ a: LiveActivity) {
        guard AppSettings.shared.prefs.liveActivities else { return }
        if let i = activities.firstIndex(where: { $0.id == a.id }) {
            guard activities[i] != a else { return }
            activities[i] = a
        } else {
            withAnimation(IslandModel.openSpring) { activities.append(a) }
        }
    }

    private func remove(_ id: String) {
        ttlTasks[id]?.cancel(); ttlTasks[id] = nil
        guard activities.contains(where: { $0.id == id }) else { return }
        withAnimation(IslandModel.closeSpring) { activities.removeAll { $0.id == id } }
    }

    func removeAll() {
        withAnimation(IslandModel.closeSpring) { activities.removeAll() }
    }

    // MARK: Built-in sources

    private var tracking = false

    /// Focus timer and a live match become capsules when the pill is busy showing
    /// something else (music or the score), so they are never hidden.
    func startBuiltIns() {
        guard !tracking else { return }
        tracking = true
        observeBuiltIns()
    }

    private func observeBuiltIns() {
        withObservationTracking({
            _ = FocusTimer.shared.running
            _ = FocusTimer.shared.phase
            _ = NowPlaying.shared.hasMedia
            _ = FootballService.shared.live
            _ = AppSettings.shared.prefs.liveActivities
        }, onChange: { [weak self] in
            Task { @MainActor in self?.observeBuiltIns(); self?.syncBuiltIns() }
        })
        syncBuiltIns()
    }

    func syncBuiltIns() {
        let t = FocusTimer.shared
        let pillShowsTimer = !NowPlaying.shared.hasMedia && FootballService.shared.pillMatch == nil
        if t.running && !pillShowsTimer {
            ActivityCenter.start(id: "builtin.timer", symbol: t.phase == .halfTime ? "cup.and.saucer.fill" : "timer",
                                 text: t.label, tint: Color(nsColor: Look.shared.accentNS),
                                 endDate: Date().addingTimeInterval(TimeInterval(t.remaining)))
        } else {
            ActivityCenter.end(id: "builtin.timer")
        }
        // A live match gets a capsule only when the pill itself is not already showing the score.
        if let m = FootballService.shared.live, m.isLive, FootballService.shared.pillMatch == nil,
           AppSettings.shared.prefs.footballMode, !AppSettings.shared.prefs.spoilerFree {
            ActivityCenter.start(id: "builtin.match", symbol: "soccerball",
                                 text: "\(m.home.abbr) \(m.homeScore)-\(m.awayScore) \(m.away.abbr)", tint: Color(red: 1, green: 0.3, blue: 0.3))
        } else {
            ActivityCenter.end(id: "builtin.match")
        }
    }
}

// MARK: - Satellite layer (drawn beside the pill, never changes its shape)

struct SatelliteLayer: View {
    private let center = ActivityCenter.shared
    private let model = IslandModel.shared

    var body: some View {
        let list = center.visible
        // Alternate sides: 1st right, 2nd left, 3rd right, 4th left.
        let right = list.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let left = list.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        let hidden = model.expanded || model.currentPermission != nil
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(left.reversed()) { SatelliteCapsule(activity: $0, edge: .trailing) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 12)
            Color.clear.frame(width: model.size.width, height: 1)
            HStack(spacing: 6) {
                ForEach(right) { SatelliteCapsule(activity: $0, edge: .leading) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
        }
        .frame(width: IslandMetrics.window.width, alignment: .top)
        .padding(.top, 4)
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(hidden ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: hidden)
        .allowsHitTesting(false)
    }
}

struct SatelliteCapsule: View {
    let activity: LiveActivity
    let edge: Edge

    var body: some View {
        let theme = Theme.current
        HStack(spacing: 5) {
            Image(systemName: activity.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(activity.tint == .white ? theme.primary : activity.tint)
                .symbolRenderingMode(.hierarchical)
            if let end = activity.endDate {
                Text(timerInterval: Date()...max(end, Date().addingTimeInterval(1)), countsDown: true)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.primary)
                    .frame(minWidth: 34)
            } else if let start = activity.startDate {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.primary)
                    .frame(minWidth: 34)
            } else {
                Text(activity.text)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule(style: .continuous).fill(theme.pill))
        .overlay(Capsule(style: .continuous).strokeBorder(theme.dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
        .transition(.asymmetric(
            insertion: .move(edge: edge == .leading ? .leading : .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.7)),
            removal: .opacity.combined(with: .scale(scale: 0.6))))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activity.text)
    }
}
