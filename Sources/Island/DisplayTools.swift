import AppKit
import SwiftUI
import ApplicationServices
import Observation

// MARK: - Display off, Lock, Clean keyboard

@Observable @MainActor
final class DisplayTools {
    static let shared = DisplayTools()
    /// Last action, for the Tools page and for tests (isolated instances never really sleep the display).
    private(set) var lastAction = ""

    /// `pmset displaysleepnow` works without admin rights.
    func displayOff() {
        lastAction = "displaysleepnow"
        guard !Env.isolated else { return }
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    /// There is no public lock API (SACLockScreenImmediate is private, so it is not used).
    /// Documented alternatives, in order: Control+Command+Q when Accessibility is already granted;
    /// otherwise the screen saver, which locks at once when System Settings > Lock Screen is set to
    /// "Require password: Immediately".
    func lock() {
        guard !Env.isolated else { lastAction = AXIsProcessTrusted() ? "lock:ctrl-cmd-q" : "lock:screensaver"; return }
        if !Env.noPermissions && AXIsProcessTrusted() {
            lastAction = "lock:ctrl-cmd-q"
            let src = CGEventSource(stateID: .combinedSessionState)
            let q: CGKeyCode = 12
            let down = CGEvent(keyboardEventSource: src, virtualKey: q, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: q, keyDown: false)
            down?.flags = [.maskCommand, .maskControl]; up?.flags = [.maskCommand, .maskControl]
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        } else {
            lastAction = "lock:screensaver"
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        }
        IslandModel.shared.setExpanded(false)
    }

    private func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

// MARK: - Clean keyboard
//
// Swallows keyboard events for 60 seconds so the keys can be wiped. Needs Accessibility (an active
// event tap). Escape hatches: hold Esc for 3 seconds, press Stop in the Tools page, or wait: it ends
// by itself after 60 seconds. If macOS disables the tap, it ends at once.

/// Pure logic for the Esc-hold escape hatch (unit-testable).
struct EscHold {
    var since: Date?
    static let needed: TimeInterval = 3
    /// Feed every key event; returns true once Esc has been held long enough.
    mutating func feed(keyCode: Int, down: Bool, at now: Date) -> Bool {
        guard keyCode == 53 else { since = nil; return false }
        if !down { since = nil; return false }
        if since == nil { since = now }
        return now.timeIntervalSince(since!) >= Self.needed
    }
}

@Observable @MainActor
final class CleanKeyboard {
    static let shared = CleanKeyboard()
    static let duration: TimeInterval = 60

    enum State: Equatable { case idle, active, needsAccessibility }
    private(set) var state: State = .idle
    private(set) var endsAt: Date?
    private(set) var swallowed = 0

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored var esc = EscHold()

    func start() {
        guard state != .active else { return }
        if Env.noPermissions || Env.isolated {
            // Test instances never trigger the Accessibility prompt.
            state = AXIsProcessTrusted() ? .idle : .needsAccessibility
            if state == .needsAccessibility { return }
            if Env.isolated { return }
        }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            state = .needsAccessibility
            return
        }
        // keyDown, keyUp, flagsChanged and system-defined (media keys).
        var mask: CGEventMask = 0
        for t in [CGEventType.keyDown, .keyUp, .flagsChanged] { mask |= (1 << CGEventMask(t.rawValue)) }
        mask |= (1 << 14)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: cleanKeyboardCallback, userInfo: refcon) else {
            state = .needsAccessibility
            return
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        state = .active
        swallowed = 0
        esc = EscHold()
        let end = Date().addingTimeInterval(Self.duration)
        endsAt = end
        let t = Timer(fire: end, interval: 0, repeats: false) { _ in MainActor.assumeIsolated { CleanKeyboard.shared.stop() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        ActivityCenter.start(id: "cleankeyboard", symbol: "keyboard", text: "Clean keys", tint: .yellow, endDate: end)
        IslandModel.shared.enqueue(Peek(symbol: "keyboard", title: "Keyboard locked for 60 s", subtitle: "Hold Esc to exit", tint: .yellow, duration: 3.5))
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        let was = state == .active
        state = .idle; endsAt = nil
        ActivityCenter.end(id: "cleankeyboard")
        if was { IslandModel.shared.enqueue(Peek(symbol: "keyboard", title: "Keyboard unlocked", tint: .green, duration: 1.8)) }
    }

    /// Returns true when the event must be swallowed.
    func handle(type: CGEventType, keyCode: Int) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            stop(); return false
        case .keyDown, .keyUp:
            if esc.feed(keyCode: keyCode, down: type == .keyDown, at: Date()) { stop(); return true }
            swallowed += 1
            return true
        default:
            swallowed += 1
            return true
        }
    }
}

private func cleanKeyboardCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<CleanKeyboard>.fromOpaque(refcon).takeUnretainedValue()
    let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let swallow = MainActor.assumeIsolated { owner.handle(type: type, keyCode: code) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

// MARK: - Tools page

struct ToolsView: View {
    let theme: Theme
    private let tools = DisplayTools.shared
    private let clean = CleanKeyboard.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                toolButton("moon.zzz.fill", "Display off", "Sleeps the screen now") { tools.displayOff() }
                toolButton("lock.fill", "Lock screen", AXIsProcessTrusted() ? "Control Command Q" : "Starts the screen saver") { tools.lock() }
                toolButton(clean.state == .active ? "stop.circle.fill" : "keyboard", clean.state == .active ? "Stop" : "Clean keyboard",
                           clean.state == .active ? "Ends the 60 s lock" : "Blocks keys for 60 s") {
                    clean.state == .active ? clean.stop() : clean.start()
                }
            }
            if clean.state == .active, let end = clean.endsAt {
                HStack(spacing: 4) {
                    Text("Keys are locked:").foregroundStyle(theme.secondary)
                    Text(timerInterval: Date()...end, countsDown: true).monospacedDigit().foregroundStyle(theme.primary)
                    Text("left. Hold Esc for 3 seconds to exit early.").foregroundStyle(theme.secondary)
                }
                .font(.system(size: 11))
            } else if clean.state == .needsAccessibility {
                note("Clean keyboard needs Accessibility: System Settings, Privacy & Security, Accessibility, Glance. Glance only asks when you press the button.")
            } else {
                note("Lock uses Control Command Q when Accessibility is already allowed, otherwise the screen saver (it locks at once if Lock Screen asks for a password immediately).")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(theme.tertiary).fixedSize(horizontal: false, vertical: true)
    }

    private func toolButton(_ symbol: String, _ title: String, _ sub: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(theme.primary)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.primary)
                Text(sub).font(.system(size: 10)).foregroundStyle(theme.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 86)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.card))
        }
        .buttonStyle(PressScaleStyle())
    }
}
