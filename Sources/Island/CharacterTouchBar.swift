import AppKit
import SwiftUI

/// The character on the Touch Bar: a full-width system-modal strip (the same private API as the
/// Cinema Touch Bar) shown while something is going on (music, Claude Code, a movie poof, the
/// Shelf, a meeting) and dismissed when the Mac goes back to idle. Deny / Approve on the strip
/// answer the same request as the island's buttons. Silently does nothing on Macs without a
/// Touch Bar (TouchBarAPI.available is false there). Settings can show the same strip in a window.
@MainActor
final class CharacterTouchBar: NSObject, NSTouchBarDelegate {
    static let shared = CharacterTouchBar()
    private static let trayID = "app.glanceformac.glance.character"
    private static let itemID = NSTouchBarItem.Identifier("app.glanceformac.glance.character.strip")

    private var bar: NSTouchBar?
    private var barStrip: CharacterStripView?
    private(set) var presented = false
    private var registered = false
    private var dismissTask: Task<Void, Never>?
    /// Settings preview window strips (same content as the real bar).
    private var previewStrips: [CharacterStripView] = []
    /// Settings is showing the Touch Bar preview (it follows every tick).
    var previewing: Bool { !previewStrips.isEmpty }

    private static let activeStates: Set<CharacterState> = [.music, .movie, .thinking, .approval, .finished, .shelf, .meeting]

    private var wanted: Bool {
        let e = CharacterEngine.shared
        guard TouchBarAPI.available, e.active, e.prefs.touchBar, !TouchBarGlow.shared.presented else { return false }
        if Env.isolated && ProcessInfo.processInfo.environment["GLANCE_TEST_TOUCHBAR"] != "1" { return false }
        if AppSettings.shared.prefs.islandHidden { return false }
        return Self.activeStates.contains(e.frame.state) && !e.frame.gone
    }

    /// Called whenever the character's frame changes.
    func update() {
        let content = Self.content()
        for s in previewStrips { s.apply(content) }
        if wanted {
            dismissTask?.cancel(); dismissTask = nil
            if !presented { present() }
            barStrip?.apply(content)
        } else if presented {
            barStrip?.apply(content)
            guard dismissTask == nil else { return }
            // A short grace period so a quick state change does not flash the bar.
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self else { return }
                self.dismissTask = nil
                if !self.wanted { self.dismiss() }
            }
        }
    }

    private func present() {
        if !registered {
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
    }

    private func dismiss() {
        guard presented, let b = bar else { return }
        TouchBarAPI.dismiss(b)
        presented = false
        bar = nil
        barStrip = nil
    }

    nonisolated func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        MainActor.assumeIsolated {
            guard identifier == Self.itemID else { return nil }
            let item = NSCustomTouchBarItem(identifier: identifier)
            let v = CharacterStripView(frame: NSRect(x: 0, y: 0, width: 1085, height: 30))
            v.apply(Self.content())
            barStrip = v
            item.view = v
            return item
        }
    }

    // MARK: Approve / Deny (same path as the island buttons)

    static func answer(allow: Bool) {
        let model = IslandModel.shared
        guard let r = model.permissions.first else { return }
        if model.currentPermission == nil { model.revealPermissions = true }   // Prompter's minimal mode
        model.answer(id: r.id, allow: allow)
    }

    // MARK: Preview window (Macs without a Touch Bar can still see the strip)

    private var previewWindow: NSWindow?

    func showPreview() {
        if previewWindow == nil {
            let strip = CharacterStripView(frame: NSRect(x: 0, y: 0, width: 1085, height: 30))
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 1101, height: 46))
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor(white: 0.04, alpha: 1).cgColor
            strip.frame.origin = CGPoint(x: 8, y: 8)
            host.addSubview(strip)
            let w = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Touch Bar preview (1085 x 30 points)"
            w.isReleasedWhenClosed = false
            w.contentView = host
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { CharacterTouchBar.shared.previewStrips.removeAll(); CharacterTouchBar.shared.previewWindow = nil }
            }
            previewStrips = [strip]
            previewWindow = w
        }
        previewStrips.forEach { $0.apply(Self.content()) }
        NSApp.activate(ignoringOtherApps: true)
        previewWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: What the strip says

    struct Content: Equatable {
        var frame = CharacterFrame()
        var packID = ""
        var text = NSAttributedString()
        var buttons = false
        var runner = false
        enum Wave: Equatable { case none, right, centre }
        var wave = Wave.none
        var shimmer = false
    }

    static func content() -> Content {
        let e = CharacterEngine.shared
        var c = Content()
        c.frame = e.frame
        c.packID = e.pack?.id ?? ""
        let white = NSColor(white: 0.93, alpha: 1), dim = NSColor(white: 0.6, alpha: 1)
        let orange = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1), green = NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)
        func t(_ parts: [(String, NSColor)]) -> NSAttributedString {
            let s = NSMutableAttributedString()
            for (txt, col) in parts {
                s.append(NSAttributedString(string: txt, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: col == dim ? .regular : .medium), .foregroundColor: col]))
            }
            return s
        }
        let np = NowPlaying.shared
        switch e.frame.state {
        case .idle:
            let day = Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            let shelf = ShelfStore.shared.items.count
            c.text = t([("All quiet", white), ("   \(day)" + (shelf > 0 ? "   \(shelf) on Shelf" : ""), dim)])
        case .sleeping:
            c.text = t([("Resting", white), ("   wakes when you move the mouse", dim)])
        case .music:
            c.text = t([(np.title.isEmpty ? "Playing" : np.title, white), (np.artist.isEmpty ? "" : ", " + np.artist, dim)])
            c.wave = .right
            c.runner = !e.frame.stills
        case .movie:
            c.wave = .centre
        case .thinking:
            let n = e.frame.clones
            c.text = t([("Claude Code:", orange), (" working on it", white), (n > 0 ? "   \(n) helper\(n == 1 ? "" : "s") running" : "", dim)])
            c.shimmer = !e.frame.stills
        case .approval:
            let summary = IslandModel.shared.permissions.first.map { String($0.summary.split(separator: "\n").first ?? "").prefix(70) } ?? ""
            c.text = t([("Claude Code needs you:", orange), (" " + (summary.isEmpty ? "approve?" : String(summary)), white)])
            c.buttons = !IslandModel.shared.permissions.isEmpty
        case .finished:
            c.text = t([("✓ ", green), ("All done", white)])
        case .shelf:
            c.text = t([(e.lastShelfName.isEmpty ? "Added to Shelf" : e.lastShelfName, white), ("   added to Shelf", dim)])
        case .meeting:
            let mins = CalendarService.shared.nextStart.map { max(1, Int(($0.timeIntervalSinceNow / 60).rounded(.up))) } ?? 5
            c.text = t([("\(CalendarService.shared.nextTitle ?? "Meeting") in \(mins) min", white), (CalendarService.shared.nextTime.map { "   " + $0 } ?? "", dim)])
        }
        return c
    }
}

/// The strip itself (AppKit + Core Animation, 1085 x 30 points).
final class CharacterStripView: NSView {
    private let slot = CharacterRigView(frame: NSRect(x: 6, y: 0, width: 44, height: 30))
    private let runner = CharacterRigView(frame: NSRect(x: 60, y: 0, width: 34, height: 30))
    private let label = NSTextField(labelWithString: "")
    private let shimmer = CAGradientLayer()
    private let waveHost = CALayer()
    private var waveBars: [CALayer] = []
    private var deny: NSButton!
    private var approve: NSButton!
    private var content = CharacterTouchBar.Content()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 6
        slot.compact = true
        addSubview(slot)
        runner.isHidden = true
        addSubview(runner)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        shimmer.startPoint = CGPoint(x: 0, y: 0.5); shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.colors = [NSColor.clear.cgColor, NSColor(red: 0.43, green: 0.7, blue: 1, alpha: 0.9).cgColor, NSColor.clear.cgColor]
        shimmer.cornerRadius = 1
        shimmer.isHidden = true
        layer?.addSublayer(shimmer)
        layer?.addSublayer(waveHost)
        for _ in 0..<12 {
            let b = CALayer()
            b.backgroundColor = NSColor(red: 0.78, green: 0.72, blue: 1, alpha: 1).cgColor
            b.cornerRadius = 1.5
            waveHost.addSublayer(b); waveBars.append(b)
        }
        deny = button("Deny", blue: false, action: #selector(denyTapped))
        approve = button("Approve", blue: true, action: #selector(approveTapped))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func button(_ title: String, blue: Bool, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        if blue { b.bezelColor = .systemBlue; b.keyEquivalent = "" }
        b.isHidden = true
        addSubview(b)
        return b
    }

    @objc private func denyTapped() { MainActor.assumeIsolated { CharacterTouchBar.answer(allow: false) } }
    @objc private func approveTapped() { MainActor.assumeIsolated { CharacterTouchBar.answer(allow: true) } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }

    func apply(_ c: CharacterTouchBar.Content) {
        let pack = MainActor.assumeIsolated { CharacterEngine.shared.pack }
        content = c
        slot.isHidden = c.frame.state == .music && c.runner
        slot.apply(c.frame, pack: pack)
        runner.isHidden = !c.runner
        if c.runner {
            var rf = c.frame; rf.clones = 0
            runner.apply(rf, pack: pack)
            startRunner()
        } else {
            runner.layer?.removeAnimation(forKey: "run")
        }
        label.attributedStringValue = c.text
        deny.isHidden = !c.buttons
        approve.isHidden = !c.buttons
        shimmer.isHidden = !c.shimmer
        waveHost.isHidden = c.wave == .none
        needsLayout = true
        layoutSubtreeIfNeeded()
        animateExtras()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var right = bounds.width - 8
        if !approve.isHidden {
            approve.sizeToFit(); deny.sizeToFit()
            approve.frame = NSRect(x: right - approve.frame.width, y: (h - 22) / 2, width: approve.frame.width, height: 22)
            right = approve.frame.minX - 6
            deny.frame = NSRect(x: right - deny.frame.width, y: (h - 22) / 2, width: deny.frame.width, height: 22)
            right = deny.frame.minX - 10
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let waveW: CGFloat = 12 * 5
        switch content.wave {
        case .right:
            waveHost.frame = CGRect(x: right - waveW, y: 6, width: waveW, height: h - 12)
            right = waveHost.frame.minX - 10
        case .centre:
            waveHost.frame = CGRect(x: (bounds.width - waveW) / 2, y: 6, width: waveW, height: h - 12)
        case .none: break
        }
        for (i, b) in waveBars.enumerated() {
            b.frame = CGRect(x: CGFloat(i) * 5, y: waveHost.bounds.height * 0.3, width: 3, height: waveHost.bounds.height * 0.4)
        }
        let left: CGFloat = 58
        let textW = min(label.intrinsicContentSize.width, max(0, right - left))
        if content.wave == .right {
            label.frame = NSRect(x: right - textW, y: (h - 18) / 2, width: textW, height: 18)
        } else {
            label.frame = NSRect(x: left, y: (h - 18) / 2, width: max(0, right - left), height: 18)
        }
        shimmer.frame = CGRect(x: left, y: 3, width: min(220, max(0, right - left)), height: 2)
        CATransaction.commit()
    }

    private func startRunner() {
        guard let l = runner.layer, l.animation(forKey: "run") == nil else { return }
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = 60; a.toValue = max(200, bounds.width * 0.62)
        a.duration = 7; a.repeatCount = .infinity
        a.isAdditive = true
        a.fromValue = 0; a.toValue = max(200, bounds.width * 0.62) - 60
        a.preferredFrameRateRange = CharacterRigView.rate
        l.add(a, forKey: "run")
    }

    private func animateExtras() {
        let still = content.frame.stills
        shimmer.removeAllAnimations()
        if !shimmer.isHidden && !still {
            let a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = -120; a.toValue = 120; a.duration = 1.6; a.repeatCount = .infinity
            a.preferredFrameRateRange = CharacterRigView.rate
            shimmer.add(a, forKey: "s")
        }
        for (i, b) in waveBars.enumerated() {
            b.removeAllAnimations()
            guard !waveHost.isHidden, !still else { continue }
            let a = CABasicAnimation(keyPath: "transform.scale.y")
            a.fromValue = 0.5; a.toValue = content.wave == .centre ? 1.4 : 2.1
            a.duration = 0.45 + Double(i % 5) * 0.09
            a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.preferredFrameRateRange = CharacterRigView.rate
            b.add(a, forKey: "w")
        }
    }
}
