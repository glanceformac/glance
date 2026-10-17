import AppKit
import SwiftUI

final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(origin: .zero, size: IslandMetrics.window),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the menu bar (mainMenu = 24, statusBar = 25).
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        // .transient: hidden by Mission Control / App Exposé (so it never covers the Spaces bar),
        // still on every Space and over full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view with an always-active tracking area so pointer moves reach us
/// even though the panel is never key.
final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    var onMove: (() -> Void)?
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); onMove?() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onMove?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel. Uses event monitors (no polling) to decide when the panel
/// should accept the mouse, and when to expand / collapse.
@MainActor
final class IslandWindowController {
    let panel = IslandPanel()
    private let model = IslandModel.shared
    private var monitors: [Any] = []
    private var expandTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var watchdog: Timer?
    private var outsideSince: Date?

    init() {
        let root = IslandRootView()
        let host = TrackingHostingView(rootView: root)
        host.sizingOptions = []
        host.onMove = { [weak self] in self?.pointerMoved() }
        panel.contentView = host
        position()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        // Another app taking focus: re-check the pointer straight away.
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        // Switching Spaces: close (unless something must stay on screen).
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.expanded, !self.model.isSticky else { return }
                self.model.setExpanded(false)
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp], handler: { [weak self] e in
            self?.handle(e, local: false)
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .mouseExited, .leftMouseUp], handler: { [weak self] e in
            self?.handle(e, local: true); return e
        }) { monitors.append(l) }
        // Esc closes the island while it has keyboard focus (Clipboard search).
        if let k = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            guard let self, e.window === self.panel, e.keyCode == 53 else { return e }
            self.model.openedByHotkey = false
            self.model.setExpanded(false)
            return nil
        }) { monitors.append(k) }
        // Clicking the closed pill also expands it.
        if let c = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] e in
            guard let self else { return e }
            if !self.model.expanded, e.window === self.panel {
                // Clicks on the in-pill video controls are theirs; elsewhere the pill opens the panel.
                if self.model.hoverControls {
                    let x = NSEvent.mouseLocation.x - self.islandRect().midX
                    if abs(x) < 78 { return e }
                    self.model.hoverControls = false
                }
                if self.model.peek != nil { self.model.dismissPeek() }
                self.model.setExpanded(true)
            }
            return e
        }) { monitors.append(c) }

        withObservationTracking({ _ = model.size; _ = model.page; _ = model.expanded }, onChange: { [weak self] in
            Task { @MainActor in self?.stateChanged() }
        })
    }

    // MARK: Drag-to-Shelf detection and global clicks

    private var dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
    private var mouseDownInIsland = false

    private func handle(_ e: NSEvent, local: Bool) {
        switch e.type {
        case .leftMouseDown:
            dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
            mouseDownInIsland = false
            // Click elsewhere closes an island opened with ⌃⌥V.
            if model.openedByHotkey, !islandRect().contains(NSEvent.mouseLocation) {
                model.openedByHotkey = false
                model.setExpanded(false)
            }
        case .leftMouseDragged:
            if local { mouseDownInIsland = true }
            detectShelfDrag()
        case .leftMouseUp:
            endShelfDrag()
        case .mouseMoved:
            // Buttons are up, so any drag is over.
            if model.shelfDragActive { endShelfDrag() }
        default: break
        }
        pointerMoved()
    }

    /// A content drag (drag pasteboard changed since mouse-down) near the island opens the Shelf drop zone.
    private func detectShelfDrag() {
        guard !mouseDownInIsland, !model.shelfDragActive, model.currentPermission == nil else { return }
        guard NSPasteboard(name: .drag).changeCount != dragCountAtMouseDown else { return }
        let hot = islandRect(IslandMetrics.closed).insetBy(dx: -90, dy: -60)
        guard hot.contains(NSEvent.mouseLocation) else { return }
        if model.peek != nil { model.dismissPeek() }
        withAnimation(IslandModel.openSpring) {
            model.editing = false
            model.page = .shelf
            model.shelfDragActive = true
        }
        model.setExpanded(true)
        panel.ignoresMouseEvents = false
    }

    private func endShelfDrag() {
        guard model.shelfDragActive else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            self.model.shelfDragActive = false
            self.pointerMoved()
        }
    }

    /// The Clipboard tab needs keyboard focus for search; the panel is non-activating,
    /// so the app in front stays active and gets focus back when the island closes.
    private func updateKeyFocus() {
        let wantsKey = model.expanded && (model.page == .clipboard || model.page == .today || model.page == .prompter || model.page == .tools || model.page == .system
            || (model.page == .dev && AppSettings.shared.prefs.dev.lastTab == .terminal)) && model.celebration == nil // MARK: feat/claude-dev: terminal
        if wantsKey, !panel.isKeyWindow {
            panel.makeKey()
        } else if !wantsKey, panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    private var screen: SafeScreen { SafeScreen.primary }

    func position() {
        guard screen.isReal else { return }   // no screen right now: wait for the next screen change
        let f = screen.frame
        let size = IslandMetrics.window
        // MARK: feat/system-media (GLANCE_TEST_OFFSCREEN=1: isolated test panel renders far off-screen, never over the real island)
        let off: CGFloat = (Env.isolated && ProcessInfo.processInfo.environment["GLANCE_TEST_OFFSCREEN"] == "1") ? -30000 : 0
        // MARK: wip/cinema-h (GLANCE_TEST_CORNER=1: isolated visible test panel at the bottom-left, away from the real island)
        if Env.isolated && ProcessInfo.processInfo.environment["GLANCE_TEST_CORNER"] == "1" {
            panel.setFrame(NSRect(x: f.minX, y: f.minY + 60, width: size.width, height: size.height), display: true)
            return
        }
        panel.setFrame(NSRect(x: f.midX - size.width / 2 + off, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    /// Current island rect in screen coordinates.
    func islandRect(_ size: CGSize? = nil) -> NSRect {
        let s = size ?? model.size
        let f = screen.frame
        let inset = IslandGeometry.topInset // feat/controls: Pill height offset
        return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height - inset, width: s.width, height: s.height)
    }

    private func stateChanged() {
        withObservationTracking({ _ = model.size; _ = model.page; _ = model.expanded }, onChange: { [weak self] in
            Task { @MainActor in self?.stateChanged() }
        })
        updateKeyFocus()
        updateWatchdog()
        // Camera must stop the moment the Mirror isn't on screen.
        if !(model.expanded && model.page == .mirror && model.celebration == nil) { Mirror.shared.stop() }
        if model.isSticky { collapseTask?.cancel() }
        pointerMoved()
    }

    /// Safety net, only while expanded: if the pointer has been outside for 1.5 s and nothing
    /// needs the island open, collapse, whatever events were missed (fast exits, menu bar,
    /// app switches). A light 0.25 s check, stopped as soon as the island closes.
    private func updateWatchdog() {
        if model.expanded {
            guard watchdog == nil else { return }
            outsideSince = nil
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.watchdogTick() }
            }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            watchdog = t
        } else {
            watchdog?.invalidate()
            watchdog = nil
            outsideSince = nil
        }
    }

    private func watchdogTick() {
        guard model.expanded else { updateWatchdog(); return }
        let inside = islandRect().insetBy(dx: -14, dy: -14).contains(NSEvent.mouseLocation)
        if inside || model.isSticky || NSEvent.pressedMouseButtons != 0 {
            outsideSince = nil
            return
        }
        if outsideSince == nil { outsideSince = Date() }
        if let s = outsideSince, Date().timeIntervalSince(s) >= max(1.5, IslandGeometry.collapseDelay + 0.5) { // feat/controls
            outsideSince = nil
            model.setExpanded(false)
        }
    }

    /// Show / Hide Glance from the menu bar (the app keeps running).
    func setHidden(_ hidden: Bool) {
        if hidden {
            model.setExpanded(false)
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        } else {
            position()
            panel.orderFrontRegardless()
        }
    }

    private func pointerMoved() {
        guard !AppSettings.shared.prefs.islandHidden else { return }
        let p = NSEvent.mouseLocation
        let inside = islandRect().insetBy(dx: -2, dy: -2).contains(p)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        // After ⌃⌥V, normal hover behaviour resumes once the pointer has visited the island.
        if model.openedByHotkey, inside { model.openedByHotkey = false }

        if model.expanded || model.currentPermission != nil {
            expandTask?.cancel()
            let keep = islandRect().insetBy(dx: -14, dy: -14).contains(p)
            if keep || model.isSticky {
                collapseTask?.cancel()
                collapseTask = nil
            } else if collapseTask == nil, model.expanded {
                collapseTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(IslandGeometry.collapseDelay)) // feat/controls
                    guard !Task.isCancelled, let self else { return }
                    self.collapseTask = nil
                    if !self.model.isSticky { self.model.setExpanded(false) }
                }
            }
        } else {
            let hot = islandRect(model.closedSize).insetBy(dx: -4, dy: -2).contains(p) ||
                (model.peek != nil && inside)
            let lift = hot && model.peek == nil
            if model.hoveringClosed != lift { model.hoveringClosed = lift }
            // A Chrome video is playing: hovering shows controls inside the pill; a click opens the panel.
            let cinema = ChromeAmbilight.shared
            let controlsMode = AppSettings.shared.prefs.cinemaExtension && AppSettings.shared.prefs.cinemaHoverControls
                && cinema.videoContext && model.peek == nil && model.celebration == nil
            if controlsMode {
                expandTask?.cancel(); expandTask = nil
                if model.hoverControls != hot {
                    withAnimation(.easeInOut(duration: 0.2)) { model.hoverControls = hot }
                    if hot { cinema.showEnds() }
                }
                return
            } else if model.hoverControls {
                model.hoverControls = false
            }
            if hot && AppSettings.shared.prefs.hoverToOpen { // feat/controls: hover-to-open toggle
                if expandTask == nil {
                    expandTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(110))
                        guard !Task.isCancelled, let self else { return }
                        self.expandTask = nil
                        if self.model.peek != nil { self.model.dismissPeek() }
                        self.model.setExpanded(true)
                    }
                }
            } else {
                expandTask?.cancel()
                expandTask = nil
            }
        }
    }
}
