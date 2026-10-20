import AppKit
import SwiftUI
import EventKit
import IOKit.ps
import Observation

// MARK: - Calendar (EventKit)

@Observable @MainActor
final class CalendarService {
    static let shared = CalendarService()
    var nextTitle: String?
    var nextTime: String?
    var nextColor: Color = .orange
    var accessDenied = false
    /// A (timed) calendar event is happening right now: used by the context rules ("in a meeting").
    private(set) var eventNow = false
    /// Start of the next timed event that has not started yet (the character's meeting watch).
    private(set) var nextStart: Date? // MARK: wip/character

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var kickoffTimer: Timer?
    @ObservationIgnored private var announced: Set<String> = []

    /// "Kick-off in 5": whistle 5 minutes before the next event, with Join if it has a video link.
    private func scheduleKickoff(_ e: EKEvent?) {
        kickoffTimer?.invalidate()
        guard AppSettings.shared.prefs.meetingKickoff, let e else { return }
        let key = (e.eventIdentifier ?? e.title ?? "") + "\(e.startDate.timeIntervalSince1970)"
        guard !announced.contains(key) else { return }
        let fire = e.startDate.addingTimeInterval(-300)
        let title = e.title ?? "Meeting"
        let url = MeetingLinks.joinURL(for: e)
        let go = {
            MainActor.assumeIsolated {
                CalendarService.shared.announced.insert(key)
                IslandModel.shared.celebrate(.kickoff(title: title, joinURL: url))
            }
        }
        if fire <= Date() { if e.startDate > Date() { go() }; return }
        let t = Timer(fire: fire, interval: 0, repeats: false) { _ in go() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        kickoffTimer = t
    }

    func start() {
        if Env.noPermissions {
            nextTitle = "Design review"; nextTime = "Tomorrow 10:30"; nextColor = .blue
            return
        }
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess: begin()
        case .notDetermined:
            store.requestFullAccessToEvents { granted, _ in
                Task { @MainActor in
                    if granted { self.begin() } else { self.accessDenied = true }
                }
            }
        default: accessDenied = true
        }
    }

    private func begin() {
        accessDenied = false
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarService.shared.refresh() }
        }
        refresh()
    }

    func refresh() {
        guard !accessDenied, !Env.noPermissions else { return }
        let now = Date()
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now))!
        let pred = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
        if let e = events.first {
            nextTitle = e.title
            let f = DateFormatter()
            f.timeStyle = .short
            f.dateStyle = .none
            let day = cal.isDateInToday(e.startDate) ? "" : "Tomorrow "
            nextTime = e.startDate <= now ? "Now · until \(f.string(from: e.endDate))" : day + f.string(from: e.startDate)
            if let c = e.calendar?.color { nextColor = Color(nsColor: c) }
            eventNow = e.startDate <= now && e.endDate > now && !e.isAllDay
        } else {
            nextTitle = nil
            nextTime = nil
            eventNow = false
        }
        nextStart = events.first { $0.startDate > now }?.startDate // MARK: wip/character
        scheduleKickoff(events.first { $0.startDate > now })
        IslandContext.shared.reevaluate()
        // Re-check when the next event starts/ends, or in 15 min at most.
        var nextChange: Date = now.addingTimeInterval(900)
        if let e = events.first { nextChange = e.startDate > now ? e.startDate : e.endDate }
        let interval = max(30, min(900, nextChange.timeIntervalSince(now) + 1))
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { CalendarService.shared.refresh() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

// MARK: - Focus timer

@Observable @MainActor
final class FocusTimer {
    static let shared = FocusTimer()
    /// Match mode: first half -> half-time break -> second half -> full-time.
    enum Phase: String { case idle, firstHalf, halfTime, secondHalf }
    var remaining: Int = 25 * 60
    var running = false
    var phase: Phase = .idle
    @ObservationIgnored private var endDate: Date?
    @ObservationIgnored private var timer: Timer?

    private var match: Bool { AppSettings.shared.prefs.focusMatch }
    var halfLength: Int { AppSettings.shared.prefs.timerMinutes * 60 }
    var breakLength: Int { (AppSettings.shared.prefs.timerMinutes >= 45 ? 15 : 5) * 60 }
    var total: Int { phase == .halfTime ? breakLength : halfLength }
    var progress: Double { total > 0 ? 1 - Double(remaining) / Double(total) : 0 }
    var label: String { String(format: "%02d:%02d", remaining / 60, remaining % 60) }
    var phaseLabel: String {
        guard match else { return "" }
        switch phase { case .idle: return "Kick-off"; case .firstHalf: return "1st half"; case .halfTime: return "Half-time"; case .secondHalf: return "2nd half" }
    }

    func toggle() { running ? pause() : startTimer() }

    func startTimer() {
        if phase == .idle { phase = match ? .firstHalf : .idle }
        if remaining <= 0 { remaining = total }
        endDate = Date().addingTimeInterval(TimeInterval(remaining))
        running = true
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { FocusTimer.shared.tick() } }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        tick()
        running = false
        timer?.invalidate()
        timer = nil
    }

    /// Stopping a focus half early counts as a Distraction.
    func reset() {
        if match, (phase == .firstHalf || phase == .secondHalf), remaining < halfLength - 30 {
            FocusMatch.shared.distraction()
        }
        running = false
        timer?.invalidate()
        timer = nil
        phase = .idle
        remaining = halfLength
    }

    private func tick() {
        guard let end = endDate, running else { return }
        remaining = max(0, Int(end.timeIntervalSinceNow.rounded()))
        guard remaining == 0 else { return }
        running = false
        timer?.invalidate()
        timer = nil
        IslandModel.shared.flash(.timer, seconds: 3)
        let celebrate = AppSettings.shared.prefs.celebrations
        switch (match, phase) {
        case (true, .firstHalf):
            FocusMatch.shared.goal()
            phase = .halfTime
            remaining = breakLength
            show(.whistle(fullTime: false, title: "HALF-TIME", detail: FocusMatch.shared.scoreLine), peekTitle: "Half-time")
            startTimer() // the break runs on its own
        case (true, .halfTime):
            phase = .secondHalf
            remaining = halfLength
            IslandModel.shared.enqueue(Peek(symbol: "sportscourt.fill", title: "Second half", subtitle: "Press play to kick off", tint: .green, duration: 3))
            Feedback.haptic(.levelChange)
        case (true, .secondHalf):
            FocusMatch.shared.goal()
            phase = .idle
            remaining = halfLength
            show(.whistle(fullTime: true, title: "FULL-TIME", detail: FocusMatch.shared.scoreLine), peekTitle: "Full-time")
        default:
            phase = .idle
            remaining = halfLength
            if IslandContext.shared.soundsAllowed { NSSound(named: "Glass")?.play() }
            if celebrate {
                IslandModel.shared.celebrate(.crowdWave(title: "TIME'S UP", score: "\(AppSettings.shared.prefs.timerMinutes) min focus done"))
            } else {
                IslandModel.shared.enqueue(Peek(symbol: "timer", title: "Time's up", subtitle: "\(AppSettings.shared.prefs.timerMinutes) min focus done",
                                                tint: Color(nsColor: Look.shared.accentNS), duration: 4))
            }
        }
    }

    private func show(_ k: CelebrationKind, peekTitle: String) {
        if AppSettings.shared.prefs.celebrations { IslandModel.shared.celebrate(k) }
        else { IslandModel.shared.enqueue(Peek(symbol: "flag.fill", title: peekTitle, subtitle: FocusMatch.shared.scoreLine, duration: 3)) }
        Feedback.haptic(.levelChange)
    }
}

// MARK: - Battery (IOKit power source notifications)

@MainActor
final class BatteryMonitor {
    static let shared = BatteryMonitor()
    private var source: CFRunLoopSource?
    private var wasCharging: Bool?
    private var lastLowWarning = 100

    func start() {
        let ctx = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let src = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { BatteryMonitor.shared.changed() } }
        }, ctx)?.takeRetainedValue() else { return }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        wasCharging = read()?.plugged
    }

    private func read() -> (percent: Int, plugged: Bool, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let state = d[kIOPSPowerSourceStateKey] as? String
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            return (Int((Double(cur) / Double(Swift.max(max, 1)) * 100).rounded()), state == kIOPSACPowerValue, charging)
        }
        return nil
    }

    private func changed() {
        guard let b = read() else { return }
        defer { wasCharging = b.plugged }
        guard AppSettings.shared.prefs.batteryPeeks else { return }
        if let was = wasCharging, was != b.plugged {
            if b.plugged {
                IslandModel.shared.enqueue(Peek(symbol: "bolt.fill", title: b.charging ? "Charging" : "Connected",
                                                subtitle: "\(b.percent)%", tint: .green))
            } else {
                IslandModel.shared.enqueue(Peek(symbol: Self.symbol(b.percent), title: "On Battery",
                                                subtitle: "\(b.percent)%", tint: b.percent <= 20 ? .red : .white))
            }
            lastLowWarning = 100
        } else if !b.plugged, (b.percent == 20 || b.percent == 10), b.percent < lastLowWarning {
            lastLowWarning = b.percent
            IslandModel.shared.enqueue(Peek(symbol: "battery.25", title: "Low Battery", subtitle: "\(b.percent)%", tint: .red, duration: 3.5))
        }
    }

    static func symbol(_ p: Int) -> String {
        switch p { case 88...: "battery.100"; case 63...: "battery.75"; case 38...: "battery.50"; case 13...: "battery.25"; default: "battery.0" }
    }
}

// MARK: - App launch peeks (NSWorkspace)

@MainActor
final class AppLaunchMonitor {
    static let shared = AppLaunchMonitor()
    private var observer: NSObjectProtocol?
    private var lastPeek = Date.distantPast
    private var perApp: [String: Date] = [:]
    private let startedAt = Date()

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { AppLaunchMonitor.shared.launched(app) }
        }
    }

    private func launched(_ app: NSRunningApplication) {
        guard AppSettings.shared.prefs.appLaunchPeeks,
              app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              Date().timeIntervalSince(startedAt) > 8 else { return }
        let id = app.bundleIdentifier ?? app.localizedName ?? "?"
        let now = Date()
        // Rate limits: one launch peek every 4 s overall, same app once per minute.
        guard now.timeIntervalSince(lastPeek) > 4, now.timeIntervalSince(perApp[id] ?? .distantPast) > 60 else { return }
        lastPeek = now
        perApp[id] = now
        let icon = app.icon
        icon?.size = NSSize(width: 64, height: 64)
        IslandModel.shared.enqueue(Peek(icon: icon, title: "Opened", subtitle: app.localizedName ?? "App"))   // [icon] Opened ... Notes
    }
}

// MARK: - Focus / Do Not Disturb (best effort)

/// macOS has no public Focus API. We read ~/Library/DoNotDisturb/DB/Assertions.json,
/// which reflects manually toggled Focus modes. Scheduled/automatic Focus is not
/// reliably reflected there, and the file may be unreadable without Full Disk Access.
@MainActor
final class FocusMonitor {
    static let shared = FocusMonitor()
    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private(set) var active: String?   // MARK: feat/productivity (read by the Focus tool)
    private(set) var available = false
    private var pending: Task<Void, Never>?

    private var dbDir: String { NSHomeDirectory() + "/Library/DoNotDisturb/DB" }

    func start() {
        guard source == nil, !Env.noPermissions else { return }
        active = readActive()
        guard available else { return }
        dirFD = open(dbDir, O_EVTONLY)
        guard dirFD >= 0 else { available = false; return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: [.write, .rename, .delete], queue: .main)
        s.setEventHandler { MainActor.assumeIsolated { FocusMonitor.shared.scheduleCheck() } }
        let fd = dirFD
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }

    private func scheduleCheck() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.check()
        }
    }

    private func check() {
        let now = readActive()
        guard now != active else { return }
        let was = active
        active = now
        guard AppSettings.shared.prefs.focusPeeks else { return }
        if let name = now {
            IslandModel.shared.enqueue(Peek(symbol: "moon.fill", title: name, subtitle: "On", tint: .indigo))
        } else if let name = was {
            IslandModel.shared.enqueue(Peek(symbol: "moon", title: name, subtitle: "Off", tint: .gray))
        }
    }

    private func readActive() -> String? {
        guard let data = FileManager.default.contents(atPath: dbDir + "/Assertions.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            available = false
            return nil
        }
        available = true
        let store = (obj["data"] as? [[String: Any]])?.first ?? [:]
        let records = store["storeAssertionRecords"] as? [[String: Any]] ?? []
        guard let rec = records.last,
              let details = rec["assertionDetails"] as? [String: Any],
              let mode = details["assertionDetailsModeIdentifier"] as? String else { return nil }
        return Self.modeName(mode)
    }

    private static func modeName(_ id: String) -> String {
        if let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/Library/DoNotDisturb/DB/ModeConfigurations.json"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cfgs = ((obj["data"] as? [[String: Any]])?.first?["modeConfigurations"]) as? [String: Any],
           let cfg = cfgs[id] as? [String: Any],
           let name = (cfg["mode"] as? [String: Any])?["name"] as? String {
            return name
        }
        return "Focus"
    }
}

// MARK: - Theme (island + macOS appearance + optional wallpaper)

@MainActor
enum ThemeSwitcher {
    static func toggle() {
        let s = AppSettings.shared
        let newTheme: IslandTheme = s.prefs.theme == .darkMatte ? .whiteMatte : .darkMatte
        withAnimation(.easeInOut(duration: 0.35)) { s.prefs.theme = newTheme }
        let dark = newTheme == .darkMatte
        if s.prefs.setSystemAppearance {
            AppleScriptRunner.run("tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)")
        }
        if s.prefs.swapWallpaper {
            let path = dark ? s.prefs.darkWallpaper : s.prefs.lightWallpaper
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                for screen in NSScreen.screens {
                    // Only points the desktop at another image; nothing is deleted.
                    try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                }
            }
        }
    }
}

// MARK: - Shortcut actions

@MainActor
enum Shortcuts {
    static func run(_ k: ShortcutKind) {
        let ws = NSWorkspace.shared
        switch k {
        case .youtube: ws.open(URL(string: "https://www.youtube.com")!)
        case .messages: openApp("com.apple.MobileSMS")
        case .mail: openApp("com.apple.mail")
        case .notes: openApp("com.apple.Notes")
        case .downloads: ws.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
        case .recents:
            let recents = "/System/Library/CoreServices/Finder.app/Contents/Resources/MyLibraries/myDocuments.cannedSearch"
            if FileManager.default.fileExists(atPath: recents) { ws.open(URL(fileURLWithPath: recents)) }
            else { openApp("com.apple.finder") }
        case .screenshot: openApp("com.apple.screenshot.launcher")
        case .clipboard:
            withAnimation(IslandModel.openSpring) { IslandModel.shared.page = .clipboard }
            return
        case .mirror:
            withAnimation(IslandModel.openSpring) { IslandModel.shared.page = IslandModel.shared.page == .mirror ? .widgets : .mirror }
            return
        }
        IslandModel.shared.setExpanded(false)
    }

    static func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
