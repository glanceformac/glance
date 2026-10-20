import AppKit
import SwiftUI

/// Private Touch Bar APIs (DFRFoundation + NSTouchBar class methods), as used by MTMR / Pock.
/// Checked at runtime; verified on macOS 15.6.1 (MacBookPro17,1).
@MainActor
enum TouchBarAPI {
    private static let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)
    private typealias PresenceFn = @convention(c) (CFString, Bool) -> Void
    private typealias CloseBoxFn = @convention(c) (Bool) -> Void

    static var available: Bool {
        dfr != nil && (NSTouchBar.self as AnyObject).responds(to: NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:"))
    }

    static func setControlStripPresence(_ id: String, _ on: Bool) {
        guard let s = dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") else { return }
        unsafeBitCast(s, to: PresenceFn.self)(id as CFString, on)
    }

    static func showCloseBox(_ on: Bool) {
        guard let s = dlsym(dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
        unsafeBitCast(s, to: CloseBoxFn.self)(on)
    }

    static func addSystemTrayItem(_ item: NSTouchBarItem) {
        _ = (NSTouchBarItem.self as AnyObject).perform(NSSelectorFromString("addSystemTrayItem:"), with: item)
    }

    static func present(_ bar: NSTouchBar, trayID: String) {
        _ = (NSTouchBar.self as AnyObject).perform(NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:"), with: bar, with: trayID)
    }

    static func dismiss(_ bar: NSTouchBar) {
        _ = (NSTouchBar.self as AnyObject).perform(NSSelectorFromString("dismissSystemModalTouchBar:"), with: bar)
    }
}

/// Full-width Touch Bar Ambilight during Cinema mode: a left-to-right gradient of the
/// spatial colours. Tap it (or the close box) to go back to the normal Touch Bar.
@MainActor
final class TouchBarGlow: NSObject, NSTouchBarDelegate {
    static let shared = TouchBarGlow()
    private static let trayID = "app.glanceformac.glance.ambilight"
    private static let itemID = NSTouchBarItem.Identifier("app.glanceformac.glance.ambilight.strip")

    private var bar: NSTouchBar?
    private var strip: GlowStripView?
    private(set) var presented = false
    private var dismissedByUser = false
    private var registered = false

    var statusLine: String {
        "api=\(TouchBarAPI.available) setting=\(AppSettings.shared.prefs.touchBarGlow) mode=\(AppSettings.shared.prefs.touchBarStyle.rawValue) presented=\(presented) barTargets/s=\(String(format: "%.1f", Double(levelTimes.filter { Date().timeIntervalSince($0) < 5 }.count) / 5))"
    }

    func begin() {
        guard AppSettings.shared.prefs.touchBarGlow, TouchBarAPI.available, !presented else { return }
        // Test instances never take over the real Touch Bar (unless explicitly asked to).
        if Env.isolated && ProcessInfo.processInfo.environment["GLANCE_TEST_TOUCHBAR"] != "1" { return }
        dismissedByUser = false
        if !registered {
            // A tray item with this identifier is required for a system-modal bar; it isn't
            // shown in the Control Strip (presence stays off).
            let tray = NSCustomTouchBarItem(identifier: NSTouchBarItem.Identifier(Self.trayID))
            tray.view = NSButton(title: "", target: nil, action: nil)
            TouchBarAPI.addSystemTrayItem(tray)
            registered = true
        }
        let b = NSTouchBar()
        b.delegate = self
        b.defaultItemIdentifiers = [Self.itemID]
        bar = b
        TouchBarAPI.showCloseBox(true)
        TouchBarAPI.present(b, trayID: Self.trayID)
        presented = true
        strip?.playIntro()
    }

    private var lastUpdate = Date.distantPast
    func update(colors: [NSColor]) {
        guard presented, !dismissedByUser else { return }
        // Touch Bar: 5 Hz normally, 2 Hz on battery saver.
        let interval = Power.shared.saving ? 0.5 : 0.25
        guard Date().timeIntervalSince(lastUpdate) >= interval else { return }
        lastUpdate = Date()
        strip?.setColours(colors, duration: 0)   // set directly: a few redraws a second, no animation
        strip?.setBarColours(colors)
    }

    /// Equaliser style: spectrum targets at ~18 Hz (8 Hz on battery saver); Core Animation tweens.
    private var lastLevels = Date.distantPast
    private var levelTimes: [Date] = []
    func levels(_ spectrum: [Float]) {
        guard presented, !dismissedByUser, AppSettings.shared.prefs.touchBarStyle == .equaliser else { return }
        let rate: Double = Power.shared.saving ? 8 : 18
        guard Date().timeIntervalSince(lastLevels) >= 1 / rate else { return }
        lastLevels = Date()
        levelTimes.append(Date()); if levelTimes.count > 120 { levelTimes.removeFirst(levelTimes.count - 120) }
        strip?.setLevels(spectrum, duration: 1.15 / rate)
    }

    /// Settings preview: show the bar briefly and play the outro on it.
    func previewOutro() {
        guard TouchBarAPI.available, AppSettings.shared.prefs.touchBarGlow else { return }
        if !presented { begin(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.endWithOutro() } } else { endWithOutro() }
    }

    /// Bars settle, ribbons fan out across the bar and fade, then the normal Touch Bar returns.
    func endWithOutro() {
        guard presented, let s = strip else { end(); return }
        s.playOutro()
        DispatchQueue.main.asyncAfter(deadline: .now() + IntroH.outroDuration + 0.05) { [weak self] in self?.end() }
    }

    func end() {
        guard presented, let b = bar else { return }
        TouchBarAPI.dismiss(b)
        presented = false
        bar = nil
        strip = nil
    }

    fileprivate func userDismissed() {
        dismissedByUser = true
        end()
    }

    nonisolated func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        MainActor.assumeIsolated {
            guard identifier == Self.itemID else { return nil }
            let item = NSCustomTouchBarItem(identifier: identifier)
            let v = GlowStripView(frame: NSRect(x: 0, y: 0, width: 1000, height: 30))
            v.onTap = { TouchBarGlow.shared.userDismissed() }
            strip = v
            item.view = v
            return item
        }
    }
}

final class GlowStripView: NSView {
    private let gradient = CAGradientLayer()
    private let label = CATextLayer()
    private let barsHost = CALayer()
    private var bars: [CALayer] = []
    private var shown: [CGFloat] = []
    private var barColours: [NSColor] = []
    private static let barCount = 32   // island look, scaled: wide capsules, clear gaps
    private static let rate = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
    var onTap: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [NSColor.black, .darkGray, .black].map(\.cgColor)
        gradient.cornerRadius = 6
        layer?.addSublayer(gradient)
        label.string = NSAttributedString(string: "C I N E M A   M O D E", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.white])
        label.alignmentMode = .center
        label.contentsScale = 2
        label.opacity = 0
        label.shadowColor = NSColor(hue: 0.93, saturation: 0.9, brightness: 1, alpha: 1).cgColor
        label.shadowRadius = 5; label.shadowOpacity = 0.9; label.shadowOffset = .zero
        layer?.addSublayer(barsHost)
        layer?.addSublayer(label)
        for _ in 0..<Self.barCount {
            let b = CALayer()
            b.backgroundColor = NSColor.white.cgColor
            b.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            barsHost.addSublayer(b)
            bars.append(b)
        }
        shown = Array(repeating: 0, count: Self.barCount)
        applyStyle()
    }

    /// Equaliser (default): bars over a dim version of the colour glow. Colour glow: the glow only.
    func applyStyle() {
        let eq = MainActor.assumeIsolated { AppSettings.shared.prefs.touchBarStyle == .equaliser }
        barsHost.isHidden = !eq
        gradient.opacity = eq ? 0.1 : 1          // equaliser: almost pure black behind the bars
    }

    func setBarColours(_ c: [NSColor]) {
        guard !c.isEmpty else { return }
        // Bright versions of the scene colours, left to right.
        let bright = c.map { col -> NSColor in
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            (col.usingColorSpace(.sRGB) ?? col).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return NSColor(hue: h, saturation: min(s, 0.85), brightness: max(b, 0.92), alpha: 1)
        }
        barColours = bright
        let n = max(1, bars.count - 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, l) in bars.enumerated() {
            let x = Double(i) / Double(n) * Double(bright.count - 1)
            let k = min(Int(x), max(0, bright.count - 2)), f = CGFloat(x - Double(k))
            let col = bright.count > 1 ? (bright[k].usingColorSpace(.sRGB)!.blended(withFraction: f, of: bright[k + 1].usingColorSpace(.sRGB)!) ?? bright[k]) : bright[0]
            l.backgroundColor = col.cgColor
        }
        CATransaction.commit()
    }

    /// 28 analyser bands interpolated onto the bars, light spatial smoothing, thin baseline in silence.
    func setLevels(_ spec: [Float], duration: CFTimeInterval) {
        guard spec.count >= 2, !barsHost.isHidden else { return }
        let n = bars.count, H = barsHost.bounds.height
        for (i, l) in bars.enumerated() {
            func band(_ x: Double) -> Float {
                let pos = min(max(x, 0), 1) * Double(spec.count - 1)
                let k = min(Int(pos), spec.count - 2), f = Float(pos - Double(k))
                return spec[k] * (1 - f) + spec[k + 1] * f
            }
            let x = Double(i) / Double(n - 1), dx = 1 / Double(n - 1)
            let v = 0.25 * band(x - dx) + 0.5 * band(x) + 0.25 * band(x + dx)
            let target = CGFloat(min(max(v, 0), 1))            // 0 = a round dot (height = width)
            if abs(target - shown[i]) < 0.02 { continue }
            shown[i] = target
            let h = l.bounds.width + (H - l.bounds.width) * target
            let from = (l.presentation() ?? l).bounds.size.height
            CATransaction.begin(); CATransaction.setDisableActions(true)
            l.bounds.size.height = h
            CATransaction.commit()
            let a = CABasicAnimation(keyPath: "bounds.size.height")
            a.fromValue = from; a.toValue = h; a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            a.preferredFrameRateRange = Self.rate
            l.add(a, forKey: "h")
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }
    override func layout() {
        super.layout()
        gradient.frame = bounds.insetBy(dx: 2, dy: 1)
        label.frame = CGRect(x: 0, y: (bounds.height - 20) / 2, width: bounds.width, height: 20)
        if pendingIntro && bounds.width > 50 { DispatchQueue.main.async { self.playIntro() } }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        barsHost.frame = bounds.insetBy(dx: 8, dy: 3)          // ~3 pt margin top and bottom
        let n = CGFloat(bars.count), slot = barsHost.bounds.width / n, w = min(8, max(6, (slot - 4.5).rounded()))
        for (i, l) in bars.enumerated() {
            l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            l.bounds = CGRect(x: 0, y: 0, width: w, height: w + (barsHost.bounds.height - w) * shown[i])
            l.position = CGPoint(x: (CGFloat(i) * slot + slot / 2).rounded(), y: barsHost.bounds.midY)
            l.cornerRadius = w / 2
        }
        CATransaction.commit()
    }

    func setColours(_ c: [NSColor], duration: CFTimeInterval) {
        guard introHost == nil else { return }
        CAQuiet.animate(gradient, "colors", to: c.map(\.cgColor), duration: duration)
    }

    /// Intro H on the Touch Bar: beam + dust across the bar, CINEMA MODE centred, ~100 thin ribbons
    /// racing to the centre, pulse, opening line, then the equaliser. Core Animation only.
    private var introHost: CALayer?
    func playOutro() {
        guard bounds.width > 50 else { return }
        setLevels(Array(repeating: 0, count: 28), duration: 0.25)     // bars settle to dots first
        let target = bounds.insetBy(dx: 2, dy: 1)
        let fixed = CGSize(width: 1000, height: 28)
        let host = CALayer()
        host.bounds = CGRect(origin: .zero, size: fixed)
        host.position = CGPoint(x: target.midX, y: target.midY)
        host.setAffineTransform(CGAffineTransform(scaleX: target.width / fixed.width, y: target.height / fixed.height))
        host.cornerRadius = 6; host.masksToBounds = true
        layer?.addSublayer(host)
        let reduce = MainActor.assumeIsolated { Look.shared.reduceMotion }
        let tl = IntroH.buildOutro(in: host, size: fixed, stripCount: 80, reduceMotion: reduce)
        tl.beginTime = tl.convertTime(CACurrentMediaTime(), from: nil)
        introHost?.removeFromSuperlayer(); introHost = host
    }

    private var pendingIntro = false
    func playIntro() {
        guard bounds.width > 50 else { pendingIntro = true; return }   // not laid out yet: start on first layout
        pendingIntro = false
        introHost?.removeFromSuperlayer()
        // Built at a fixed canvas size (pre-sampled at launch), then scaled to the real bar.
        let target = bounds.insetBy(dx: 2, dy: 1)
        let fixed = CGSize(width: 1000, height: 28)
        let host = CALayer()
        host.bounds = CGRect(origin: .zero, size: fixed)
        host.position = CGPoint(x: target.midX, y: target.midY)
        host.setAffineTransform(CGAffineTransform(scaleX: target.width / fixed.width, y: target.height / fixed.height))
        host.cornerRadius = 6; host.masksToBounds = true
        layer?.addSublayer(host)
        introHost = host
        let reduce = MainActor.assumeIsolated { Look.shared.reduceMotion }
        let tl = IntroH.build(in: host, size: fixed, stripCount: 100, dustCount: 120, reduceMotion: reduce, textScale: 1.8)
        // Start the timeline now (its groups begin at local time 0); without this the whole intro
        // was already over and only the background wash played.
        tl.beginTime = tl.convertTime(CACurrentMediaTime(), from: nil)
        barsHost.isHidden = true
        label.isHidden = true
        // Background wash follows the ribbons (left warm, right cool, concentrating at the centre).
        if !reduce {
            // Background wash follows the ribbons: left / centre / right of the ring colours.
            let ring = IntroH.glowColours()
            let colours = CAKeyframeAnimation(keyPath: "colors")
            colours.values = (ring.values ?? []).map { v -> Any in
                let r = v as! [CGColor]
                return [r[3], r[2], r[1]]
            }
            colours.keyTimes = ring.keyTimes; colours.duration = ring.duration
            let op = IntroH.glowOpacity()
            op.values = (op.values ?? []).map { Float(($0 as! Float) * 0.55) }
            let start = gradient.convertTime(CACurrentMediaTime(), from: nil)
            for a in [colours, op] {
                a.beginTime = start; a.fillMode = .both; a.isRemovedOnCompletion = false; a.preferredFrameRateRange = IntroH.rate
                gradient.add(a, forKey: "intro-" + (a.keyPath ?? ""))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + IntroH.duration) { [weak self] in
            guard let self else { return }
            self.introHost?.removeFromSuperlayer(); self.introHost = nil
            self.gradient.removeAnimation(forKey: "intro-colors"); self.gradient.removeAnimation(forKey: "intro-opacity")
            self.applyStyle()
        }
    }

    override func touchesBegan(with event: NSEvent) { onTap?() }
    override func mouseDown(with event: NSEvent) { onTap?() }
}

// MARK: - Control Strip helper (GlanceBar.app) as a login item

import ServiceManagement

@MainActor
enum IslandBarHelper {
    nonisolated static let bundleID = "app.glanceformac.glance.bar"

    /// Registers the tiny IslandBar helper (Contents/Library/LoginItems) so the Control Strip
    /// button survives restarts and works even when Glance is quit.
    static func update() {
        guard !AppIdentity.isTestBuild else { return } // MARK: wip/character
        let svc = SMAppService.loginItem(identifier: bundleID)
        let log = ChromeAmbilight.log
        if AppSettings.shared.prefs.touchBarButton {
            // Re-register if Glance moved or was reinstalled (./build.sh install replaces the
            // bundle, and launchd's job then points at the deleted copy: "Could not find and/or
            // execute program", so the helper is never relaunched). The stamp changes with the
            // bundle's path, inode and the helper binary's modification date.
            let key = "IslandBarRegisteredPath"
            let here = stamp()
            if svc.status == .enabled, Env.defaults.string(forKey: key) != here {
                log.info("GlanceBar: re-registering login item for this copy of Glance")
                try? svc.unregister()
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
            }
            if svc.status != .enabled {
                do { try svc.register(); Env.defaults.set(here, forKey: key) }
                catch { log.error("GlanceBar register failed: \(error.localizedDescription, privacy: .public)") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { launchIfMissing() }
            watchTermination()
        } else {
            if let o = terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); terminationObserver = nil }
            try? svc.unregister()
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
        }
    }

    private static var terminationObserver: NSObjectProtocol?

    private static func stamp() -> String {
        let here = Bundle.main.bundlePath
        let fm = FileManager.default
        let inode = (try? fm.attributesOfItem(atPath: here)[.systemFileNumber] as? Int) ?? 0
        let bin = here + "/Contents/Library/LoginItems/GlanceBar.app/Contents/MacOS/GlanceBar"
        let mtime = ((try? fm.attributesOfItem(atPath: bin)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
        return "\(here)|\(inode)|\(Int(mtime))"
    }

    /// Starts the helper if it isn't running (backup for launchd's own relaunch).
    private static func launchIfMissing() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/GlanceBar.app")
        guard AppSettings.shared.prefs.touchBarButton,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
              FileManager.default.fileExists(atPath: url.path) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
            if let err { ChromeAmbilight.log.error("GlanceBar launch failed: \(err.localizedDescription, privacy: .public)") }
        }
    }

    /// If the helper dies while Glance is running, bring it back (launchd normally does this
    /// within ~10 s; this covers a broken or throttled launchd job).
    private static func watchTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == bundleID else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { MainActor.assumeIsolated { launchIfMissing() } }
        }
    }

    static var status: String {
        switch SMAppService.loginItem(identifier: bundleID).status {
        case .enabled: return "enabled"
        case .requiresApproval: return "needs approval in System Settings › General › Login Items"
        case .notRegistered: return "not registered"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }
}
