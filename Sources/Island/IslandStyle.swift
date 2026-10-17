import AppKit
import SwiftUI

// MARK: feat/controls — Glance shape (Notch | Pill) and size settings, provided from one place.

enum IslandStyle: String, Codable, CaseIterable {
    /// Flat top flush with the screen edge, small outward "ears" like a MacBook notch.
    case notch
    /// Floating capsule: every corner rounded, optionally a little below the top edge.
    case pill

    var title: String { self == .notch ? "Notch" : "Pill" }
}

/// The island outline. Notch: flush top + ears. Pill: rounded on all four corners.
/// Every layer that follows the island (panel clip, border, glow mask, celebrations, snapshots)
/// gets its shape from `IslandGeometry.outline(...)`, so the shape is decided in one place.
struct IslandOutline: Shape {
    var ear: CGFloat
    var radius: CGFloat
    /// Top corner radius (Pill).
    var top: CGFloat
    /// 0 = Notch, 1 = Pill. Both shapes use the same nine segments, so every point is blended
    /// and a shape change morphs smoothly instead of jumping at a threshold.
    var pill: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(ear, radius), AnimatablePair(top, pill)) }
        set { ear = newValue.first.first; radius = newValue.first.second; top = newValue.second.first; pill = newValue.second.second }
    }

    // Points: start, top end, then per corner (control 1, control 2, end) and the edge end after it.
        private func notchPts(_ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
        let e = min(ear, w / 4), r = min(radius, (w - 2 * e) / 2, h - e), k: CGFloat = 0.552
        return [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0),
                CGPoint(x: w - e * k, y: 0), CGPoint(x: w - e, y: e * (1 - k)), CGPoint(x: w - e, y: e),
                CGPoint(x: w - e, y: h - r),
                CGPoint(x: w - e, y: h - r * 0.28), CGPoint(x: w - e - r * 0.28, y: h), CGPoint(x: w - e - r, y: h),
                CGPoint(x: e + r, y: h),
                CGPoint(x: e + r * 0.28, y: h), CGPoint(x: e, y: h - r * 0.28), CGPoint(x: e, y: h - r),
                CGPoint(x: e, y: e),
                CGPoint(x: e, y: e * (1 - k)), CGPoint(x: e * k, y: 0), CGPoint(x: 0, y: 0)]
    }

    private func pillPts(_ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
        let t = min(top, w / 2, h / 2), r = min(radius, w / 2, h - t), c: CGFloat = 0.448 // circular corners (true capsule when closed)
        return [CGPoint(x: t, y: 0), CGPoint(x: w - t, y: 0),
                CGPoint(x: w - t * c, y: 0), CGPoint(x: w, y: t * c), CGPoint(x: w, y: t),
                CGPoint(x: w, y: h - r),
                CGPoint(x: w, y: h - r * c), CGPoint(x: w - r * c, y: h), CGPoint(x: w - r, y: h),
                CGPoint(x: r, y: h),
                CGPoint(x: r * c, y: h), CGPoint(x: 0, y: h - r * c), CGPoint(x: 0, y: h - r),
                CGPoint(x: 0, y: t),
                CGPoint(x: 0, y: t * c), CGPoint(x: t * c, y: 0), CGPoint(x: t, y: 0)]
    }

    func points(in rect: CGRect) -> [CGPoint] {
        let w = rect.width, h = rect.height
        let m = min(max(pill, 0), 1)
        let a = m < 0.999 ? notchPts(w, h) : [], b = m > 0.001 ? pillPts(w, h) : []
        let pts: [CGPoint] = m <= 0.001 ? a : m >= 0.999 ? b : zip(a, b).map { CGPoint(x: $0.x + ($1.x - $0.x) * m, y: $0.y + ($1.y - $0.y) * m) }
        return pts.map { CGPoint(x: $0.x + rect.minX, y: $0.y + rect.minY) }
    }

    func path(in rect: CGRect) -> Path {
        let q = points(in: rect)
        var p = Path()
        p.move(to: q[0]); p.addLine(to: q[1])
        p.addCurve(to: q[4], control1: q[2], control2: q[3]); p.addLine(to: q[5])
        p.addCurve(to: q[8], control1: q[6], control2: q[7]); p.addLine(to: q[9])
        p.addCurve(to: q[12], control1: q[10], control2: q[11]); p.addLine(to: q[13])
        p.addCurve(to: q[16], control1: q[14], control2: q[15])
        p.closeSubpath()
        return p
    }
}

/// The edge the glow is drawn along, derived from the same outline. Notch: sides and bottom only
/// (the top is the screen edge, see GlowOutline). Pill: the whole closed outline, since it floats.
/// While morphing, the sides and bottom are blended; the top edge joins in at the half-way point.
struct IslandGlowEdge: Shape {
    var outline: IslandOutline
    var animatableData: IslandOutline.AnimatableData {
        get { outline.animatableData }
        set { outline.animatableData = newValue }
    }
    func path(in rect: CGRect) -> Path {
        if outline.pill >= 0.5 { return outline.path(in: rect) }
        let q = outline.points(in: rect)
        var p = Path()
        p.move(to: CGPoint(x: q[4].x, y: rect.minY)); p.addLine(to: q[5])
        p.addCurve(to: q[8], control1: q[6], control2: q[7]); p.addLine(to: q[9])
        p.addCurve(to: q[12], control1: q[10], control2: q[11]); p.addLine(to: CGPoint(x: q[13].x, y: rect.minY))
        return p
    }
}

@MainActor
enum IslandGeometry {
    private static var prefs: Prefs { AppSettings.shared.prefs }

    static var style: IslandStyle { prefs.islandStyle }

    /// The one shape for the island in its current state.
    static func outline(open: Bool, size: CGSize) -> IslandOutline {
        switch style {
        case .notch:
            // Unchanged from the original island: ears 7 / 12, bottom radius 14 / 30.
            return IslandOutline(ear: open ? 12 : 7, radius: open ? 30 : 14, top: 0, pill: 0)
        case .pill:
            let r = open ? 30 : size.height / 2
            return IslandOutline(ear: 0, radius: r, top: r, pill: 1)
        }
    }

    /// Ear width for content insets (0 for Pill).
    static func ear(open: Bool) -> CGFloat { style == .notch ? (open ? 12 : 7) : 0 }

    /// Distance from the top of the screen to the island (Pill only; the notch is always flush).
    static var topInset: CGFloat { style == .pill ? CGFloat(min(max(prefs.heightOffset, 0), 24)) : 0 }

    /// Closed pill scale (80...130 %).
    static var idleScale: CGFloat { CGFloat(min(max(prefs.idlePillScale, 80), 130)) / 100 }

    static func scaledClosed(_ s: CGSize) -> CGSize {
        let k = idleScale
        return CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
    }

    /// Expanded panel size, from the built-in size for the page, the panel width and max height.
    static func expanded(_ base: CGSize) -> CGSize {
        let w = CGFloat(min(max(prefs.panelWidth, 600), 700))
        let extra = base.width - IslandMetrics.expanded.width // +120 for the wide Home
        let maxH = CGFloat(min(max(prefs.panelMaxHeight, 300), 400))
        return CGSize(width: w + extra, height: min(base.height, maxH))
    }

    static var collapseDelay: Double { min(max(prefs.autoCollapseDelay, 0.1), 10) }
}

// MARK: Settings section

struct IslandShapeSettingsSection: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Section("Glance shape") {
            Picker("Shape", selection: $settings.prefs.islandStyle) {
                ForEach(IslandStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(settings.prefs.islandStyle == .notch
                 ? "Flat top against the screen edge with curved ears, like a MacBook notch."
                 : "A floating capsule, rounded on every corner.")
                .font(.caption).foregroundStyle(.secondary)
            slider("Idle pill size", value: $settings.prefs.idlePillScale, range: 80...130, step: 5, unit: "%")
            if settings.prefs.islandStyle == .pill {
                slider("Height offset", value: $settings.prefs.heightOffset, range: 0...24, step: 1, unit: " pt")
            }
            slider("Panel width", value: $settings.prefs.panelWidth, range: 600...700, step: 10, unit: " pt")
            slider("Maximum height", value: $settings.prefs.panelMaxHeight, range: 300...400, step: 10, unit: " pt")
            Toggle("Open on hover", isOn: $settings.prefs.hoverToOpen)
            if !settings.prefs.hoverToOpen {
                Text("Click the island, knock or use the command palette to open it.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Pin open", isOn: $settings.prefs.pinOpen)
            Picker("Close after the pointer leaves", selection: $settings.prefs.autoCollapseDelay) {
                Text("Straight away").tag(0.32)
                Text("1 second").tag(1.0)
                Text("2 seconds").tag(2.0)
                Text("5 seconds").tag(5.0)
            }
            .disabled(settings.prefs.pinOpen)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: step)
            Text("\(Int(value.wrappedValue))\(unit)").monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }
    }
}
