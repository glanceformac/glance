import AppKit
import SwiftUI
import Observation
import CoreGraphics

// MARK: - Activity rings (opt-in, off by default)
//
// Three daily rings made of COUNTS ONLY: keystrokes (a number, never which keys), cursor distance,
// and active minutes (minutes in which any input happened). Key contents are never read: the
// handler below does not even look at the event. Counting key presses needs Input Monitoring, which
// Glance asks for only when you switch this on. Totals stay on this Mac (UserDefaults).

@Observable @MainActor
final class ActivityRings {
    static let shared = ActivityRings()

    struct Day: Codable, Equatable {
        var day = ""
        var keys = 0
        var distancePts = 0.0
        var minutes: Set<Int> = []
    }

    static let goalKeys = 5000
    static let goalMeters = 500.0
    static let goalMinutes = 240

    @ObservationIgnored private(set) var today = Day()
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var lastPoint: CGPoint?
    @ObservationIgnored private var lastMinute = -1
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var dirty = false
    private static let key = "IslandRings.v1"

    var hasInputPermission: Bool { CGPreflightListenEventAccess() }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            load()
            if !Env.noPermissions && !Env.isolated && !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
            // Counting only. Neither handler reads the event.
            if let k = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ in
                MainActor.assumeIsolated { ActivityRings.shared.countKey() }
            }) { monitors.append(k) }
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel], handler: { _ in
                MainActor.assumeIsolated { ActivityRings.shared.moved() }
            }) { monitors.append(m) }
            // Typing into Glance's own windows is counted too.
            if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
                MainActor.assumeIsolated { ActivityRings.shared.countKey() }; return e
            }) { monitors.append(l) }
            lastPoint = NSEvent.mouseLocation
        } else {
            persist()
            monitors.forEach { NSEvent.removeMonitor($0) }
            monitors.removeAll()
        }
    }

    // MARK: Counting

    private func rollover() {
        let d = Self.dayString(Date())
        if today.day != d { today = Day(day: d); lastMinute = -1; dirty = true }
    }

    private func touchMinute() {
        rollover()
        let m = Int(Date().timeIntervalSince1970 / 60)
        guard m != lastMinute else { return }
        lastMinute = m
        today.minutes.insert(m)
        dirty = true
        persist()      // once a minute at most
    }

    private func countKey() {
        rollover()
        today.keys += 1
        touchMinute()
    }

    private func moved() {
        let p = NSEvent.mouseLocation
        if let l = lastPoint {
            let d = hypot(p.x - l.x, p.y - l.y)
            if d < 600 { today.distancePts += d }   // ignore display-jump teleports
        }
        lastPoint = p
        touchMinute()
    }

    // MARK: Read

    var keys: Int { today.keys }
    var minutes: Int { today.minutes.count }
    var meters: Double {
        let mm = CGDisplayScreenSize(CGMainDisplayID())
        let widthPts = SafeScreen.primary.frame.width
        guard mm.width > 0, widthPts > 0 else { return 0 }
        return today.distancePts * Double(mm.width) / Double(widthPts) / 1000
    }

    // MARK: Storage (counts only)

    private static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func load() {
        today = Day(day: Self.dayString(Date()))
        guard !Env.isolated, let d = Env.defaults.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode(Day.self, from: d), saved.day == today.day else { return }
        today = saved
    }

    func persist() {
        guard !Env.isolated, dirty, let d = try? JSONEncoder().encode(today) else { return }
        Env.defaults.set(d, forKey: Self.key)
        dirty = false
    }

    // Test hook
    func debugSet(keys: Int, meters: Double, minutes: Int) {
        today.day = Self.dayString(Date())
        today.keys = keys
        let mm = CGDisplayScreenSize(CGMainDisplayID())
        let widthPts = SafeScreen.primary.frame.width
        today.distancePts = meters * 1000 * Double(widthPts) / Double(max(mm.width, 1))
        let base = Int(Date().timeIntervalSince1970 / 60)
        today.minutes = Set((0..<minutes).map { base - $0 })
    }
}

// MARK: - View

struct RingsView: View {
    let theme: Theme
    private let rings = ActivityRings.shared

    var body: some View {
        // Updated every 5 s while visible; nothing observes the live counters.
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let enabled = AppSettings.shared.prefs.activityRings
            let k = Double(rings.keys) / Double(ActivityRings.goalKeys)
            let m = rings.meters / ActivityRings.goalMeters
            let a = Double(rings.minutes) / Double(ActivityRings.goalMinutes)
            HStack(spacing: 24) {
                ZStack {
                    ring(k, theme.accent, size: 118)
                    ring(m, .green, size: 88)
                    ring(a, .orange, size: 58)
                }
                .frame(width: 124, height: 124)
                VStack(alignment: .leading, spacing: 10) {
                    legend(theme.accent, "Keystrokes", "\(rings.keys)", "of \(ActivityRings.goalKeys)")
                    legend(.green, "Cursor distance", String(format: "%.0f m", rings.meters), String(format: "of %.0f m", ActivityRings.goalMeters))
                    legend(.orange, "Active minutes", "\(rings.minutes)", "of \(ActivityRings.goalMinutes)")
                    Text(enabled
                         ? (rings.hasInputPermission ? "Counts only. Glance never records which keys you press." : "Allow Glance in Privacy & Security, Input Monitoring to count keystrokes. Mouse and minutes already count.")
                         : "Off. Turn on in Settings, System & Media. Counts only, never key contents.")
                        .font(.system(size: 10.5)).foregroundStyle(theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
        }
        .frame(maxHeight: .infinity)
    }

    private func legend(_ c: Color, _ title: String, _ value: String, _ goal: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(title).font(.system(size: 12)).foregroundStyle(theme.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(theme.primary)
            Text(goal).font(.system(size: 11).monospacedDigit()).foregroundStyle(theme.tertiary)
        }
    }

    private func ring(_ progress: Double, _ colour: Color, size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(colour.opacity(0.18), lineWidth: 11)
            Circle().trim(from: 0, to: CGFloat(min(max(progress, 0.001), 1)))
                .stroke(colour, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}
