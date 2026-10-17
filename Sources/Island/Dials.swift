import AppKit
import SwiftUI

/// Two round desktop dials (volume, brightness) with tick-mark rings.
/// Drag around the ring (or up/down) to change the value. Scroll also works.
struct DialsView: View {
    private let vol = VolumeControl.shared
    private let bri = BrightnessControl.shared

    var body: some View {
        let theme = Theme.current
        HStack(spacing: 16) {
            Dial(value: Double(vol.volume), symbol: vol.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                 label: "Volume", theme: theme) { vol.set(Float($0)) }
            if bri.available {
                Dial(value: Double(bri.brightness), symbol: "sun.max.fill", label: "Brightness", theme: theme) { bri.set(Float($0)) }
            }
        }
        .padding(14)
        .environment(\.colorScheme, theme.dark ? .dark : .light)
    }
}

struct Dial: View {
    let value: Double
    let symbol: String
    let label: String
    let theme: Theme
    let onChange: (Double) -> Void

    private let ticks = 36
    private let arc = 270.0 // degrees covered by the ring
    @State private var dragging = false
    @State private var startValue = 0.0

    var body: some View {
        ZStack {
            if Accessibility.shared.reduceTransparency {
                Circle().fill(LinearGradient(colors: theme.matte, startPoint: .top, endPoint: .bottom))
            } else {
                VisualEffectBlur(dark: theme.dark).clipShape(Circle())
                Circle().fill(theme.pill.opacity(theme.dark ? 0.45 : 0.35))
            }
            Circle().strokeBorder(theme.cardStroke, lineWidth: 0.5)
            ForEach(0..<ticks, id: \.self) { i in
                let frac = Double(i) / Double(ticks - 1)
                let on = frac <= value + 0.0001 && value > 0
                Capsule()
                    .fill(on ? theme.primary : theme.tertiary.opacity(0.7))
                    .frame(width: 2, height: i % 5 == 0 ? 8 : 5)
                    .offset(y: -40)
                    .rotationEffect(.degrees(-arc / 2 + frac * arc))
            }
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.primary)
                    .contentTransition(.symbolEffect(.replace))
                Text("\(Int((value * 100).rounded()))")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(theme.primary)
                    .contentTransition(.numericText())
            }
        }
        .frame(width: 104, height: 104)
        .scaleEffect(dragging ? 1.04 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragging)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { dragging = true; startValue = value }
                    let c = CGPoint(x: 52, y: 52)
                    let dx = g.location.x - c.x, dy = g.location.y - c.y
                    let dist = hypot(dx, dy)
                    if dist > 22 {
                        // Angle from 12 o'clock, clockwise.
                        var a = atan2(dx, -dy) * 180 / .pi
                        a = min(max(a, -arc / 2), arc / 2)
                        onChange((a + arc / 2) / arc)
                    } else {
                        onChange(min(max(startValue - g.translation.height / 150, 0), 1))
                    }
                }
                .onEnded { _ in dragging = false }
        )
        .help(label)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { dir in
            onChange(min(max(value + (dir == .increment ? 0.0625 : -0.0625), 0), 1))
        }
    }
}

final class ScrollHostingView<Content: View>: NSHostingView<Content> {
    var onScroll: ((CGFloat, CGPoint) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.03), convert(event.locationInWindow, from: nil))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class DialsWindowController {
    private var panel: NSPanel?

    func update() {
        let on = AppSettings.shared.prefs.desktopDials
        if on, panel == nil { create() }
        if !on { panel?.orderOut(nil); panel = nil }
        BrightnessControl.shared.setWatching(on)
    }

    private func create() {
        let width: CGFloat = BrightnessControl.shared.available ? 264 : 132
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 132),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        let host = ScrollHostingView(rootView: DialsView())
        host.onScroll = { delta, point in
            MainActor.assumeIsolated {
                if point.x < 132 || !BrightnessControl.shared.available {
                    VolumeControl.shared.set(VolumeControl.shared.volume + Float(delta))
                } else {
                    BrightnessControl.shared.set(BrightnessControl.shared.brightness + Float(delta))
                }
            }
        }
        p.contentView = host
        if let s = NSScreen.screens.first {
            let vf = s.visibleFrame
            p.setFrameOrigin(NSPoint(x: vf.minX + 18, y: vf.maxY - 132 - 14))
        }
        p.orderFrontRegardless()
        panel = p
    }
}
