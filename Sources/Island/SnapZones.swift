import AppKit
import SwiftUI
import ApplicationServices
import Observation

// MARK: - Window snap zones
//
// Drag a window up towards the pill and five zone tiles drop down beneath it. Release over a tile and
// the window snaps there. Needs Accessibility (to read and move other apps' windows), which Glance
// only requests when this feature is switched on in Settings. Mouse drag events are observed only
// while the feature is on; nothing runs otherwise.

enum SnapZone: Int, CaseIterable, Identifiable {
    case left, right, topLeft, topRight, center
    var id: Int { rawValue }
    var title: String {
        switch self { case .left: "Left half"; case .right: "Right half"; case .topLeft: "Top left"; case .topRight: "Top right"; case .center: "Centre" }
    }

    /// Target frame in AppKit screen coordinates (origin bottom-left) inside `v` (the visible frame).
    func frame(in v: CGRect) -> CGRect {
        let hw = (v.width / 2).rounded(), hh = (v.height / 2).rounded()
        switch self {
        case .left: return CGRect(x: v.minX, y: v.minY, width: hw, height: v.height)
        case .right: return CGRect(x: v.minX + hw, y: v.minY, width: v.width - hw, height: v.height)
        case .topLeft: return CGRect(x: v.minX, y: v.minY + hh, width: hw, height: v.height - hh)
        case .topRight: return CGRect(x: v.minX + hw, y: v.minY + hh, width: v.width - hw, height: v.height - hh)
        case .center:
            let w = (v.width * 0.6).rounded(), h = (v.height * 0.72).rounded()
            return CGRect(x: v.midX - w / 2, y: v.midY - h / 2, width: w, height: h)
        }
    }
}

@Observable @MainActor
final class SnapZones {
    static let shared = SnapZones()

    private(set) var active = false
    private(set) var hovered: SnapZone?

    static let tileSize = CGSize(width: 58, height: 40)
    static let tileGap: CGFloat = 6
    static let stripTop: CGFloat = 46     // below the pill, from the top of the screen

    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var grabbed: AXUIElement?
    @ObservationIgnored private var startOrigin: CGPoint?
    @ObservationIgnored private var preview: NSPanel?
    @ObservationIgnored private(set) var enabled = false

    private var screen: SafeScreen { SafeScreen.primary }

    // MARK: Lifecycle

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            if !Env.noPermissions && !Env.isolated && !AXIsProcessTrusted() {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
            }
            let types: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            if let g = NSEvent.addGlobalMonitorForEvents(matching: types, handler: { e in
                MainActor.assumeIsolated { SnapZones.shared.mouse(e) }
            }) { monitors.append(g) }
        } else {
            monitors.forEach { NSEvent.removeMonitor($0) }
            monitors.removeAll()
            deactivate()
            grabbed = nil
        }
    }

    var trusted: Bool { AXIsProcessTrusted() }

    // MARK: Geometry

    /// Tile frames in AppKit screen coordinates.
    func tileFrames() -> [(SnapZone, CGRect)] {
        let f = screen.frame
        let n = CGFloat(SnapZone.allCases.count)
        let total = n * Self.tileSize.width + (n - 1) * Self.tileGap
        let x0 = f.midX - total / 2
        let top = f.maxY - Self.stripTop
        return SnapZone.allCases.enumerated().map { i, z in
            (z, CGRect(x: x0 + CGFloat(i) * (Self.tileSize.width + Self.tileGap), y: top - Self.tileSize.height,
                       width: Self.tileSize.width, height: Self.tileSize.height))
        }
    }

    func zone(at p: CGPoint) -> SnapZone? {
        tileFrames().first(where: { $0.1.insetBy(dx: -3, dy: -6).contains(p) })?.0
    }

    /// AppKit rect (bottom-left origin) to Accessibility coordinates (top-left origin of the primary screen).
    func axRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Mouse

    private func mouse(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown: grabWindow()
        case .leftMouseDragged: dragged()
        case .leftMouseUp: released()
        default: break
        }
    }

    private func grabWindow() {
        grabbed = nil; startOrigin = nil
        guard AXIsProcessTrusted() else { return }
        let p = NSEvent.mouseLocation
        var el: AXUIElement?
        let sys = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(screen.frame.maxY - p.y), &el) == .success, let el else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        var win: AXUIElement?
        if Self.attr(el, kAXRoleAttribute) as? String == kAXWindowRole as String { win = el }
        else if let w = Self.attr(el, kAXWindowAttribute) { win = (w as! AXUIElement) }
        guard let win, Self.attr(win, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole as String else { return }
        grabbed = win
        startOrigin = Self.origin(of: win)
    }

    private func dragged() {
        guard enabled, let win = grabbed, let start = startOrigin else { return }
        let p = NSEvent.mouseLocation
        let f = screen.frame
        // Only look at the window when the pointer is up near the pill; keeps drags elsewhere free.
        guard p.y > f.maxY - 170, abs(p.x - f.midX) < 260 else {
            if active { deactivate() }
            return
        }
        guard let now = Self.origin(of: win), abs(now.x - start.x) + abs(now.y - start.y) > 8 else { return }
        if !active { withAnimation(IslandModel.openSpring) { active = true } }
        setHovered(zone(at: p))
    }

    private func released() {
        defer { grabbed = nil; startOrigin = nil }
        guard active else { return }
        if let z = hovered, let win = grabbed { snap(win, to: z) }
        deactivate()
    }

    func setHovered(_ z: SnapZone?) {
        guard z != hovered else { return }
        withAnimation(.easeOut(duration: 0.12)) { hovered = z }
        updatePreview()
    }

    func deactivate() {
        guard active || hovered != nil else { return }
        withAnimation(IslandModel.closeSpring) { active = false; hovered = nil }
        updatePreview()
    }

    /// Debug / tests.
    func debugShow(_ z: SnapZone?) {
        withAnimation(IslandModel.openSpring) { active = true }
        setHovered(z)
    }

    // MARK: Moving the window

    private func snap(_ win: AXUIElement, to z: SnapZone) {
        let target = axRect(z.frame(in: screen.visibleFrame))
        var origin = target.origin
        var size = target.size
        // Size, position, size again: some windows clamp the size first.
        if let sv = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv) }
        if let pv = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv) }
        if let sv = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv) }
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    private static func origin(of win: AXUIElement) -> CGPoint? {
        guard let v = attr(win, kAXPositionAttribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    // MARK: Preview rectangle (a click-through panel showing where the window will land)

    private func updatePreview() {
        guard let z = hovered, active else { preview?.orderOut(nil); return }
        let target = z.frame(in: screen.visibleFrame).insetBy(dx: 6, dy: 6)
        if preview == nil {
            let p = NSPanel(contentRect: target, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            let v = NSView(frame: NSRect(origin: .zero, size: target.size))
            v.wantsLayer = true
            v.layer?.cornerRadius = 14
            v.layer?.borderWidth = 2
            v.autoresizingMask = [.width, .height]
            p.contentView = v
            preview = p
        }
        let accent = Look.shared.accentNS
        preview?.contentView?.layer?.backgroundColor = accent.withAlphaComponent(0.22).cgColor
        preview?.contentView?.layer?.borderColor = accent.withAlphaComponent(0.9).cgColor
        if Env.isolated {
            // Test instances never draw over the real desktop.
            preview?.setFrame(target.offsetBy(dx: -20000, dy: 0), display: false)
        } else if preview?.isVisible == true {
            preview?.animator().setFrame(target, display: true)
        } else {
            preview?.setFrame(target, display: true)
        }
        preview?.orderFrontRegardless()
    }
}

// MARK: - Zone strip (drawn under the pill inside the island window)

struct SnapZoneStrip: View {
    private let snap = SnapZones.shared

    var body: some View {
        let theme = Theme.current
        HStack(spacing: SnapZones.tileGap) {
            ForEach(SnapZone.allCases) { z in
                let on = snap.hovered == z
                ZoneGlyph(zone: z, on: on, theme: theme)
                    .frame(width: SnapZones.tileSize.width, height: SnapZones.tileSize.height)
                    .scaleEffect(on ? 1.08 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: on)
                    .accessibilityLabel(z.title)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.pill))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(theme.dark ? 0.08 : 0), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .padding(.top, SnapZones.stripTop - 6)
        .frame(width: IslandMetrics.window.width, height: IslandMetrics.window.height, alignment: .top)
        .opacity(snap.active ? 1 : 0)
        .offset(y: snap.active ? 0 : -10)
        .allowsHitTesting(false)
    }
}

struct ZoneGlyph: View {
    let zone: SnapZone
    let on: Bool
    let theme: Theme
    var body: some View {
        GeometryReader { g in
            let r = CGRect(x: 0, y: 0, width: g.size.width, height: g.size.height)
            // The zone as a fraction of a mini screen.
            let unit = zone.frame(in: CGRect(x: 0, y: 0, width: 1, height: 1))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.card.opacity(1.2))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(on ? theme.accent : theme.secondary.opacity(0.75))
                    .frame(width: r.width * unit.width - 4, height: r.height * unit.height - 4)
                    .offset(x: r.width * unit.minX + 2, y: r.height * (1 - unit.maxY) + 2)
            }
        }
    }
}
