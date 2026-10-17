import AppKit
import SwiftUI
import Observation

// MARK: - Coordinator for the system-media features (feat/system-media)
//
// Starts and stops each feature from the prefs, so a disabled feature costs nothing. One
// observation loop on the prefs; no timers here.

@MainActor
final class SystemMedia {
    static let shared = SystemMedia()
    private var last: Prefs?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        // Isolated test instances skip the normal start-up, so bring up what the sound code reads.
        if Env.isolated { VolumeControl.shared.start(); IslandContext.shared.start() }
        ActivityCenter.shared.startBuiltIns()
        SoundCenter.shared.start()
        apply(AppSettings.shared.prefs)
        observe()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ActivityRings.shared.persist() }
        }
    }

    private func observe() {
        withObservationTracking({ _ = AppSettings.shared.prefs }, onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observe()
                self.apply(AppSettings.shared.prefs)
            }
        })
    }

    /// Idempotent: each feature compares with what it already runs.
    func apply(_ p: Prefs) {
        defer { last = p }
        p.cameraGuard ? CameraGuard.shared.start() : CameraGuard.shared.stop()
        if p.screenshotShelf && (!Env.isolated || ProcessInfo.processInfo.environment["GLANCE_SCREENSHOT_DIR"] != nil) {
            ScreenshotShelf.shared.start()
        } else {
            ScreenshotShelf.shared.stop()
        }
        SnapZones.shared.setEnabled(p.snapZones)
        ActivityRings.shared.setEnabled(p.activityRings)
        DeskPet.shared.setEnabled(p.deskPet)
        if last?.capsLockHUD != p.capsLockHUD || last?.hudReplace != p.hudReplace { SoundCenter.shared.applyPrefs() }
        if last?.liveActivities != p.liveActivities {
            p.liveActivities ? ActivityCenter.shared.syncBuiltIns() : ActivityCenter.shared.removeAll()
        }
        if last?.screenshotOCR != p.screenshotOCR, p.screenshotOCR { ScreenshotShelf.shared.scan() }
    }
}

// MARK: - Activity hub: Claude runs and the socket API for long commands

@MainActor
enum ActivityHub {
    private static let claudeTint = Color(red: 0.85, green: 0.47, blue: 0.34)

    static func claudeStarted(session: String, project: String) {
        guard !session.isEmpty else { return }
        ActivityCenter.start(id: "claude.\(session)", symbol: "sparkle", text: project, tint: claudeTint, startDate: Date(), ttl: 600)
    }
    static func claudeTouched(session: String) { if !session.isEmpty { ActivityCenter.touch(id: "claude.\(session)", ttl: 600) } }
    static func claudeStopped(session: String) { ActivityCenter.end(id: "claude.\(session)") }

    /// `{"hook_event_name":"IslandActivity","action":"start|update|end","id":"build","text":"npm test","symbol":"terminal",
    ///   "tint":"green","seconds":90 (countdown) | "elapsed":true (count up),"ttl":3600}`
    static func handle(_ msg: [String: Any]) {
        guard let id = (msg["id"] as? String).map({ "ext." + String($0.prefix(40)) }) else { return }
        let action = msg["action"] as? String ?? "start"
        if action == "end" { ActivityCenter.end(id: id); return }
        let text = String((msg["text"] as? String ?? "Running").prefix(24))
        let symbol = msg["symbol"] as? String ?? "terminal"
        let tint = color(msg["tint"] as? String)
        var end: Date?
        if let s = (msg["seconds"] as? NSNumber)?.doubleValue, s > 0 { end = Date().addingTimeInterval(s) }
        let start: Date? = (msg["elapsed"] as? Bool ?? false) ? Date() : nil
        if action == "update" {
            ActivityCenter.update(id: id, symbol: symbol, text: text, tint: tint, endDate: end)
        } else {
            ActivityCenter.start(id: id, symbol: symbol, text: text, tint: tint, endDate: end, startDate: start,
                                 ttl: min((msg["ttl"] as? NSNumber)?.doubleValue ?? 3600, 86_400))
        }
    }

    private static func color(_ s: String?) -> Color {
        switch s { case "green": .green; case "orange": .orange; case "red": .red; case "blue": .blue; case "yellow": .yellow; case "purple": .purple; default: .white }
    }
}
