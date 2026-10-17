import AppKit
import SwiftUI
import ApplicationServices
import Carbon.HIToolbox

// MARK: feat/controls — Knock: double-tap a modifier key to open (or close) the island.

enum KnockKey: String, Codable, CaseIterable {
    case off, rightOption, fn, rightCommand, rightShift

    var title: String {
        switch self {
        case .off: return "Off"
        case .rightOption: return "Right Option"
        case .fn: return "Fn"
        case .rightCommand: return "Right Command"
        case .rightShift: return "Right Shift"
        }
    }

    /// Hardware key code reported in flagsChanged events.
    var keyCode: UInt16? {
        switch self {
        case .off: return nil
        case .rightOption: return UInt16(kVK_RightOption)
        case .fn: return UInt16(kVK_Function)
        case .rightCommand: return UInt16(kVK_RightCommand)
        case .rightShift: return UInt16(kVK_RightShift)
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .off: return []
        case .rightOption: return .option
        case .fn: return .function
        case .rightCommand: return .command
        case .rightShift: return .shift
        }
    }
}

/// Pure state machine (unit-testable): tap = key down then up within `maxHold`, no other
/// modifier held; knock = two taps whose downs are within `window`. Any other key or modifier
/// in between cancels, so normal Option shortcuts never trigger it.
struct KnockDetector {
    var maxHold: TimeInterval = 0.28
    var window: TimeInterval = 0.42
    private var downAt: TimeInterval?
    private var lastTapAt: TimeInterval?

    /// Feed one flagsChanged event for any key. Returns true when a knock completes.
    mutating func feed(keyCode: UInt16, isDown: Bool, otherModifiers: Bool, target: UInt16, time: TimeInterval) -> Bool {
        guard keyCode == target else { reset(); return false }
        if isDown {
            if otherModifiers { reset(); return false }
            if let last = lastTapAt, time - last > window { lastTapAt = nil }
            downAt = time
            return false
        }
        guard let d = downAt else { return false }
        downAt = nil
        guard time - d <= maxHold else { reset(); return false }
        if let last = lastTapAt, d - last <= window {
            lastTapAt = nil
            return true
        }
        lastTapAt = d
        return false
    }

    /// A normal key press (keyDown) between taps cancels the knock.
    mutating func reset() { downAt = nil; lastTapAt = nil }
}

@MainActor
enum KnockMonitor {
    private static var monitors: [Any] = []
    private static var detector = KnockDetector()

    /// Global key monitoring needs Accessibility permission (macOS rule for key-related events
    /// from other apps). Without it the global monitor simply receives nothing; the local one
    /// still works while Glance has focus.
    static var trusted: Bool { AXIsProcessTrusted() }

    static func update() {
        stop()
        let key = AppSettings.shared.prefs.knockKey
        guard let code = key.keyCode else { return }
        let handler: (NSEvent) -> Void = { e in
            MainActor.assumeIsolated { handle(e, target: code, key: key) }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { e in handler(e); return e }) { monitors.append(l) }
    }

    static func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        detector.reset()
    }

    private static func handle(_ e: NSEvent, target: UInt16, key: KnockKey) {
        if e.type == .keyDown { detector.reset(); return }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isDown = flags.contains(key.flag) && e.keyCode == target
        let others = !flags.subtracting(key.flag).subtracting([.capsLock, .numericPad, .function]).isEmpty
        if detector.feed(keyCode: e.keyCode, isDown: isDown, otherModifiers: others, target: target, time: e.timestamp) {
            knocked()
        }
    }

    /// Debug/tests: feed synthetic events (keyCode, down/up, seconds).
    static func debugFeed(_ events: [(UInt16, Bool, TimeInterval)]) -> Int {
        guard let code = AppSettings.shared.prefs.knockKey.keyCode else { return 0 }
        var d = KnockDetector()
        var n = 0
        for (k, down, t) in events where d.feed(keyCode: k, isDown: down, otherModifiers: false, target: code, time: t) { n += 1 }
        return n
    }

    static func knocked() {
        let m = IslandModel.shared
        guard !AppSettings.shared.prefs.islandHidden else { return }
        if m.expanded {
            m.openedByHotkey = false
            m.setExpanded(false)
        } else {
            m.openFromCommand(page: m.page == .volume || m.page == .brightness || m.page == .mirror ? .widgets : m.page)
        }
        Feedback.haptic(.alignment)
    }

    /// Asks macOS for Accessibility permission. Called only when the user turns Knock on
    /// (or presses "Grant access"), never at launch, and never in test mode.
    static func requestPermission() {
        guard !Env.noPermissions, !AXIsProcessTrusted() else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}
