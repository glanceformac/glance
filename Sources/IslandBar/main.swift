// IslandBar: tiny login-item helper that puts a Glance button in the Touch Bar's Control
// Strip. Tap = show / hide the island (launches Glance if it isn't running).
// Uses the private DFRFoundation / NSTouchBar APIs (as MTMR / Pock do).
//
// Staying in the Control Strip:
// - At login the helper can start before the Control Strip has finished loading, and the
//   button then silently never appears. So the button is re-asserted after launch (1, 3, 8,
//   20 and 60 s), on wake / screen wake / session switch, and whenever the Control Strip
//   process is replaced (launch notification, plus a cheap 30 s pid check as a safety net).
// - launchd (SMAppService login item) restarts the helper if it is killed or crashes.
import AppKit

final class BarDelegate: NSObject, NSApplicationDelegate {
    static let itemID = NSTouchBarItem.Identifier("app.glanceformac.glance.bar.toggle")
    static let stripBundleID = "com.apple.controlstrip"
    let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)
    var item: NSCustomTouchBarItem?
    private var stripPID: pid_t = 0
    private var watchdog: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        // One helper only (launchd and Glance could both start one at the same moment).
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: "app.glanceformac.glance.bar")
            .contains(where: { $0.processIdentifier != me && $0.processIdentifier < me }) {
            NSLog("GlanceBar: another helper is running, exiting")
            exit(0)
        }

        let i = NSCustomTouchBarItem(identifier: Self.itemID)
        let img = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Glance") ?? NSImage()
        let b = NSButton(image: img, target: self, action: #selector(tap))
        b.bezelColor = NSColor(white: 0.2, alpha: 1)
        i.view = b
        item = i
        stripPID = currentStripPID()
        assertPresence(reason: "launch")

        // Retries: the Control Strip may not be ready yet right after login.
        for delay in [1.0, 3, 8, 20, 60] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.assertPresence(reason: "retry \(Int(delay))s")
            }
        }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Give the Touch Bar a moment to come back, then once more a bit later.
                for d in [1.0, 5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + d) { self?.assertPresence(reason: note.name.rawValue) }
                }
            }
        }
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.stripBundleID else { return }
            self?.stripRestarted(pid: app.processIdentifier, via: "launch notification")
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.ControlStrip.Restarted"), object: nil, queue: .main) { [weak self] _ in
            self?.assertPresence(reason: "ControlStrip.Restarted")
        }

        // Safety net: a cheap pid comparison every 30 s (no Touch Bar work unless it changed).
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let pid = self.currentStripPID()
            if pid != 0, pid != self.stripPID { self.stripRestarted(pid: pid, via: "watchdog") }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private func currentStripPID() -> pid_t {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.stripBundleID).first?.processIdentifier ?? 0
    }

    private func stripRestarted(pid: pid_t, via: String) {
        guard pid != stripPID else { return }
        stripPID = pid
        // The new Control Strip needs a moment before it accepts tray items.
        for d in [0.5, 2, 6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                self?.assertPresence(reason: "ControlStrip \(pid) (\(via)) +\(d)s")
            }
        }
    }

    /// (Re)adds the tray item and turns its Control Strip presence on. Idempotent.
    func assertPresence(reason: String) {
        guard let item else { return }
        let cls = NSTouchBarItem.self as AnyObject
        _ = cls.perform(NSSelectorFromString("removeSystemTrayItem:"), with: item)
        _ = cls.perform(NSSelectorFromString("addSystemTrayItem:"), with: item)
        typealias PresenceFn = @convention(c) (CFString, Bool) -> Void
        if let s = dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") {
            unsafeBitCast(s, to: PresenceFn.self)(Self.itemID.rawValue as CFString, true)
        }
        NSLog("GlanceBar: presence asserted (\(reason))")
    }

    @objc func tap() {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "app.glanceformac.glance").isEmpty {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.glanceformac.glance") ?? URL(fileURLWithPath: "/Applications/Glance.app")
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let u = URL(string: "glance://toggle") {
            NSWorkspace.shared.open(u)
        }
    }
}

let app = NSApplication.shared
let delegate = BarDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
