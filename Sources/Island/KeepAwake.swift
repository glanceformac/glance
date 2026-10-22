import AppKit
import SwiftUI
import IOKit.pwr_mgt
import Observation

// MARK: feat/controls — Keep Mac awake (IOPMAssertion, no admin rights, no polling)

/// How long to keep the Mac awake.
enum KeepAwakeDuration: Equatable {
    case minutes(Int)
    case until(Date)
    case indefinitely

    static let presets: [KeepAwakeDuration] = [.minutes(15), .minutes(60), .minutes(120), .minutes(240)]

    var title: String {
        switch self {
        case .minutes(let m): return m < 60 ? "\(m) min" : "\(m / 60) h"
        case .until(let d): return "Until \(d.formatted(date: .omitted, time: .shortened))"
        case .indefinitely: return "Indefinitely"
        }
    }

    func endDate(from now: Date = Date()) -> Date? {
        switch self {
        case .minutes(let m): return now.addingTimeInterval(TimeInterval(m * 60))
        case .until(let d):
            // A time earlier than now means that time tomorrow.
            return d > now ? d : Calendar.current.date(byAdding: .day, value: 1, to: d)
        case .indefinitely: return nil
        }
    }
}

/// Holds one IOPMAssertion while active. A single one-shot timer ends it; nothing runs while idle.
@Observable @MainActor
final class KeepAwake {
    static let shared = KeepAwake()

    private(set) var active = false
    private(set) var endsAt: Date?
    /// The assertion currently held (0 = none). Exposed for tests/diagnostics.
    @ObservationIgnored private(set) var assertionID: IOPMAssertionID = 0
    @ObservationIgnored private var endTimer: Timer?
    @ObservationIgnored private var lastDuration: KeepAwakeDuration = .indefinitely

    static let assertionName = "Glance: Keep Mac awake"
    private static let resumeKey = "KeepAwakeResume"   // 0 = indefinitely, else end time (seconds since 1970)

    /// At launch: carry on if Keep awake was on when Glance last quit (e.g. an update) and has not ended.
    func resumeIfNeeded() {
        guard !active, let v = Env.defaults.object(forKey: Self.resumeKey) as? Double else { return }
        if v == 0 { start(.indefinitely) }
        else if v > Date().timeIntervalSince1970 + 5 { start(.until(Date(timeIntervalSince1970: v))) }
        else { Env.defaults.removeObject(forKey: Self.resumeKey) }
    }

    var statusText: String {
        guard active else { return "Off" }
        if let e = endsAt { return "On until \(e.formatted(date: .omitted, time: .shortened))" }
        return "On indefinitely"
    }

    /// Tap on the cup: on (indefinitely) / off.
    func toggle() { active ? stop(reason: .user) : start(.indefinitely) }

    func start(_ d: KeepAwakeDuration) {
        releaseAssertion()
        endTimer?.invalidate(); endTimer = nil
        let type = AppSettings.shared.prefs.keepAwakeDisplay
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep   // also keeps the system awake
            : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.assertionName as CFString, &id)
        guard r == kIOReturnSuccess else {
            NSLog("Glance: keep awake assertion failed (\(r))")
            IslandModel.shared.enqueue(Peek(symbol: "cup.and.saucer", title: "Could not keep awake", tint: .orange))
            return
        }
        assertionID = id
        lastDuration = d
        active = true
        endsAt = d.endDate()
        if let e = endsAt {
            let t = Timer(fire: e, interval: 0, repeats: false) { _ in
                MainActor.assumeIsolated { KeepAwake.shared.stop(reason: .expired) }
            }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            endTimer = t
        }
        // Remembered so an app restart (update, crash) resumes it; cleared when it is switched off or ends.
        Env.defaults.set(endsAt?.timeIntervalSince1970 ?? 0, forKey: Self.resumeKey)
        Feedback.haptic(.levelChange)
        NSLog("Glance: keep awake on (\(d.title), display=\(AppSettings.shared.prefs.keepAwakeDisplay)) id=\(id)")
        KeepAwakeStatusItem.shared.refresh()
    }

    enum StopReason { case user, expired }

    func stop(reason: StopReason) {
        guard active else { return }
        releaseAssertion()
        endTimer?.invalidate(); endTimer = nil
        Env.defaults.removeObject(forKey: Self.resumeKey)
        active = false
        endsAt = nil
        NSLog("Glance: keep awake off (\(reason == .expired ? "expired" : "user"))")
        // A peek when it ends (always on expiry; a quieter one when switched off by hand).
        IslandModel.shared.enqueue(Peek(symbol: "cup.and.saucer", title: reason == .expired ? "Keep awake ended" : "Keep awake off",
                                        tint: .white, duration: 3))
        KeepAwakeStatusItem.shared.refresh()
    }

    /// "Keep screen on" changed while active: swap the assertion type, keep the same end time.
    func displayOptionChanged() {
        guard active else { return }
        let end = endsAt
        start(end.map { .until($0) } ?? .indefinitely)
    }

    private func releaseAssertion() {
        if assertionID != 0 { IOPMAssertionRelease(assertionID); assertionID = 0 }
    }

    /// App quitting: the kernel drops the assertion with the process anyway; release explicitly.
    /// The resume marker stays, so an update or a restart by the system carries on.
    func shutdown() { releaseAssertion() }

    /// The user chose Quit: Keep awake must not come back at the next launch.
    func forgetResume() { Env.defaults.removeObject(forKey: Self.resumeKey) }

    // MARK: Menu (shared by the top-row long-press and the menu bar item)

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let head = NSMenuItem(title: "Keep Mac awake: \(statusText)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        for d in KeepAwakeDuration.presets { menu.addItem(KeepAwakeMenuAction.item(d.title, .start(d))) }
        let until = NSMenuItem(title: "Until a chosen time", action: nil, keyEquivalent: "")
        until.submenu = Self.untilMenu()
        menu.addItem(until)
        menu.addItem(KeepAwakeMenuAction.item("Indefinitely", .start(.indefinitely)))
        menu.addItem(.separator())
        let screen = KeepAwakeMenuAction.item("Keep screen on", .toggleDisplay)
        screen.state = AppSettings.shared.prefs.keepAwakeDisplay ? .on : .off
        menu.addItem(screen)
        if active {
            menu.addItem(.separator())
            menu.addItem(KeepAwakeMenuAction.item("Turn off", .stop))
        }
        return menu
    }

    /// Submenu: a time picker plus quick half-hour picks for the next 12 hours.
    private static func untilMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let picker = NSMenuItem()
        picker.view = UntilPickerView()
        m.addItem(picker)
        m.addItem(.separator())
        // Next half hour at least 10 minutes away, then hourly.
        let now = Date()
        let half: TimeInterval = 1800
        var t = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / half).rounded(.up) * half)
        if t < now.addingTimeInterval(600) { t = t.addingTimeInterval(half) }
        for _ in 0..<12 {
            m.addItem(KeepAwakeMenuAction.item(t.formatted(date: .omitted, time: .shortened), .start(.until(t))))
            t = t.addingTimeInterval(3600)
        }
        return m
    }
}

/// Target for menu items (NSMenu needs an object target).
@MainActor
final class KeepAwakeMenuAction: NSObject {
    enum Kind { case start(KeepAwakeDuration), stop, toggleDisplay }
    private let kind: Kind
    private init(_ k: Kind) { kind = k }
    private static var retained: [KeepAwakeMenuAction] = []

    static func item(_ title: String, _ k: Kind) -> NSMenuItem {
        let a = KeepAwakeMenuAction(k)
        if retained.count > 80 { retained.removeFirst(retained.count - 80) }
        retained.append(a)
        let i = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        i.target = a
        i.isEnabled = true
        return i
    }

    @objc func run() {
        switch kind {
        case .start(let d): KeepAwake.shared.start(d)
        case .stop: KeepAwake.shared.stop(reason: .user)
        case .toggleDisplay: AppSettings.shared.prefs.keepAwakeDisplay.toggle()
        }
    }
}

/// Time picker row inside the "Until a chosen time" submenu.
final class UntilPickerView: NSView {
    private let picker = NSDatePicker()
    private let button = NSButton(title: "Start", target: nil, action: nil)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 34))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.dateValue = Date().addingTimeInterval(3600)
        picker.frame = NSRect(x: 16, y: 5, width: 100, height: 24)
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 122, y: 3, width: 66, height: 28)
        button.target = self
        button.action = #selector(go)
        addSubview(picker)
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func go() {
        let date = picker.dateValue
        MainActor.assumeIsolated {
            // The picker shows only hours and minutes: use that time today (or tomorrow).
            let cal = Calendar.current
            let hm = cal.dateComponents([.hour, .minute], from: date)
            let today = cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: Date()) ?? date
            KeepAwake.shared.start(.until(today))
        }
        enclosingMenuItem?.menu?.supermenu?.cancelTracking()
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

// MARK: Top-row button: tap toggles, long-press (or right-click) shows the durations menu.

struct KeepAwakeButton: View {
    let theme: Theme
    private let awake = KeepAwake.shared
    @State private var hover = false
    @State private var longPressed = false

    static let yellow = Color(red: 1.0, green: 0.82, blue: 0.2)

    var body: some View {
        Image(systemName: awake.active ? "cup.and.saucer.fill" : "cup.and.saucer")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(awake.active ? Self.yellow : (hover ? theme.primary : theme.secondary))
            .frame(width: 28, height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.card.opacity(hover || awake.active ? 1 : 0)))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(
                LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in longPressed = true; KeepAwakeButton.showMenu() }
                    .exclusively(before: TapGesture().onEnded {
                        if longPressed { longPressed = false; return }
                        awake.toggle()
                    })
            )
            .contextMenu { KeepAwakeContextMenu() }
            .help(awake.active ? "Keep Mac awake: \(awake.statusText). Hold for options." : "Keep Mac awake. Hold for options.")
            .accessibilityLabel("Keep Mac awake")
            .accessibilityValue(awake.statusText)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { awake.toggle() }
    }

    /// Pops the durations menu under the pointer (works in the non-activating panel).
    static func showMenu() {
        let menu = KeepAwake.shared.buildMenu()
        let loc = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: NSPoint(x: loc.x - 8, y: loc.y - 6), in: nil)
    }
}

/// Right-click alternative to the long-press (same choices).
struct KeepAwakeContextMenu: View {
    var body: some View {
        ForEach(KeepAwakeDuration.presets.indices, id: \.self) { i in
            let d = KeepAwakeDuration.presets[i]
            Button(d.title) { KeepAwake.shared.start(d) }
        }
        Button("Until a chosen time…") { KeepAwakeButton.showMenu() }
        Button("Indefinitely") { KeepAwake.shared.start(.indefinitely) }
        Divider()
        Toggle("Keep screen on", isOn: Binding(get: { AppSettings.shared.prefs.keepAwakeDisplay },
                                               set: { AppSettings.shared.prefs.keepAwakeDisplay = $0 }))
        if KeepAwake.shared.active { Divider(); Button("Turn off") { KeepAwake.shared.stop(reason: .user) } }
    }
}

// MARK: Menu bar item (a cup; filled while active). Event driven, no timers.

@MainActor
final class KeepAwakeStatusItem: NSObject, NSMenuDelegate {
    static let shared = KeepAwakeStatusItem()
    private var item: NSStatusItem?

    func update() {
        // Isolated test instances never put an item in the real menu bar.
        let want = AppSettings.shared.prefs.keepAwakeMenuBar && !Env.isolated
        if want, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu()
            menu.delegate = self
            i.menu = menu
            item = i
            refresh()
        } else if !want, let i = item {
            NSStatusBar.system.removeStatusItem(i)
            item = nil
        }
    }

    func refresh() {
        guard let b = item?.button else { return }
        let on = KeepAwake.shared.active
        let img = NSImage(systemSymbolName: on ? "cup.and.saucer.fill" : "cup.and.saucer", accessibilityDescription: "Keep Mac awake")
        img?.isTemplate = true
        b.image = img
        b.toolTip = "Keep Mac awake: \(KeepAwake.shared.statusText)"
    }

    /// Menu is rebuilt only when it opens.
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menu.removeAllItems()
            let fresh = KeepAwake.shared.buildMenu()
            let toggle = KeepAwakeMenuAction.item(KeepAwake.shared.active ? "Turn off" : "Turn on (indefinitely)",
                                                  KeepAwake.shared.active ? .stop : .start(.indefinitely))
            menu.addItem(toggle)
            menu.addItem(.separator())
            for i in fresh.items where !(KeepAwake.shared.active && i.title == "Turn off") {
                fresh.removeItem(i)
                menu.addItem(i)
            }
            while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
            menu.autoenablesItems = false
        }
    }

    /// Diagnostics: titles of the menu bar menu (tests only).
    func debugTitles() -> [String] {
        guard let m = item?.menu else { return ["<no item>"] }
        menuNeedsUpdate(m)
        return m.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }
}
