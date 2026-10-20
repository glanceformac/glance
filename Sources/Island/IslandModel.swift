import AppKit
import SwiftUI
import Observation

struct Peek: Identifiable {
    let id = UUID()
    var symbol: String? = nil
    var icon: NSImage? = nil
    var title: String
    var subtitle: String? = nil
    var tint: Color = .white
    var duration: TimeInterval = 2.5
    /// Larger "done" style peek.
    var prominent = false
    /// Optional button shown in the peek (e.g. Join, Watch the replay).
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
}

enum ExpandedPage: Equatable { case widgets, clipboard, shelf, today, volume, brightness, mirror, prompter, tools /* MARK: feat/productivity */
    case system // MARK: feat/system-media
    case dev // MARK: feat/claude-dev
}

/// The camera housing on MacBooks with a notch, read from the built-in screen.
@MainActor
enum HardwareNotch {
    /// Width and height of the notch in points, or nil on screens without one.
    static var size: CGSize? {
        guard let s = NSScreen.screens.first, s.safeAreaInsets.top > 0,
              let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return nil }
        let w = s.frame.width - l.width - r.width
        guard w > 0 else { return nil }
        return CGSize(width: w, height: s.safeAreaInsets.top)
    }
    static var present: Bool { size != nil }

    /// Room kept on each side of the notch for the pill's own content (artwork, bars, scores),
    /// so nothing is drawn under the camera.
    static let sideRoom: CGFloat = 47

    /// The closed island, grown if needed so it wraps the real notch with content room either side.
    static func closedSize(fitting base: CGSize, extra: CGFloat = 0) -> CGSize {
        guard let n = size else { return base }
        return CGSize(width: max(base.width, (n.width + 2 * sideRoom + extra).rounded()),
                      height: max(base.height, n.height.rounded(.up)))
    }
}

/// Geometry of every island state. Values are points.
enum IslandMetrics {
    static let closed = CGSize(width: 220, height: 32)
    static let peek = CGSize(width: 260, height: 34)
    static let peekProminent = CGSize(width: 300, height: 42)
    static let expanded = CGSize(width: 640, height: 236)
    static let expandedTall = CGSize(width: 640, height: 372)
    static let permission = CGSize(width: 640, height: 312)
    /// Home gets wider (instead of squeezing) when five cards are showing.
    static let expandedWide = CGSize(width: 760, height: 236)
    /// Window is big enough for the largest state plus the glow pad on every side and the Pill
    /// offset: 760 + 2 x 64 = 888 wide, 400 + 24 + 64 = 488 tall (it was 840 x 420 and clipped the glow).
    static let window = CGSize(width: 900, height: 500)
}

@Observable @MainActor
final class IslandModel {
    static let shared = IslandModel()

    var expanded = false
    var editing = false
    var page: ExpandedPage = .widgets
    var peek: Peek?
    @ObservationIgnored private var peekQueue: [Peek] = []
    @ObservationIgnored private var peekTask: Task<Void, Never>?

    var permissions: [PermissionRequest] = []
    /// While prompting, approvals wait as a small amber dot on the pill until it is clicked.
    var currentPermission: PermissionRequest? {
        guard let f = permissions.first else { return nil }
        return IslandContext.shared.approvalsMinimal && !revealPermissions ? nil : f
    }
    var revealPermissions = false
    var permissionWaiting: Bool { !permissions.isEmpty && currentPermission == nil }

    /// True when the island must stay open regardless of the pointer.
    var isSticky: Bool { editing || pinned || AppSettings.shared.prefs.pinOpen /* feat/controls */ || openedByHotkey || shelfDragActive || currentPermission != nil || celebration != nil }
    /// A drag is in progress near the island (Shelf drop zone is showing).
    var shelfDragActive = false
    /// Pointer is resting on the closed pill (subtle lift).
    var hoveringClosed = false
    /// Cinema: video controls shown inside the pill instead of expanding on hover.
    var hoverControls = false
    /// Short glow event (done / deny / timer).
    var glowFlash: GlowFlash?
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    func flash(_ f: GlowFlash, seconds: Double) {
        flashTask?.cancel()
        glowFlash = f
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.glowFlash = nil
        }
    }
    /// Debug/testing only: keep the island open.
    var pinned = false

    var size: CGSize {
        if currentPermission != nil { return IslandMetrics.permission }
        // Celebrations and peeks play inside the closed pill: same shape, same size.
        if celebration != nil { return closedSize }
        if expanded {
            // MARK: feat/controls: panel width / max height settings
            if page == .clipboard || page == .today || page == .prompter || page == .tools || page == .system || page == .dev { return IslandGeometry.expanded(IslandMetrics.expandedTall) }
            if page == .widgets && homeCardCount >= 5 { return IslandGeometry.expanded(IslandMetrics.expandedWide) }
            return IslandGeometry.expanded(IslandMetrics.expanded)
        }
        return closedSize
    }

    /// Cards visible on Home right now (Now Playing only counts while something plays).
    var homeCardCount: Int {
        AppSettings.shared.visibleCards.filter { $0 != .nowPlaying || NowPlaying.shared.hasMedia || editing }.count
    }

    /// The pill: 220 x 32, or 240 x 32 while it shows a live score / focus score.
    /// On a notch Mac it never shrinks below the notch plus room for content (see HardwareNotch).
    var closedSize: CGSize { HardwareNotch.closedSize(fitting: IslandGeometry.scaledClosed(baseClosedSize)) } // feat/controls: idle pill size %

    private var baseClosedSize: CGSize {
        let wide = FootballService.shared.pillMatch != nil
            || (AppSettings.shared.prefs.focusScoreInPill && AppSettings.shared.prefs.focusMatch && !NowPlaying.shared.hasMedia)
        let base = wide ? CGSize(width: 240, height: 32) : IslandMetrics.closed
        return HardwareNotch.closedSize(fitting: base, extra: wide ? 20 : 0)
    }

    var cornerRadius: CGFloat {
        if currentPermission != nil || expanded { return 30 }
        return 14
    }

    static let openSpring = Animation.spring(response: 0.42, dampingFraction: 0.76, blendDuration: 0)
    static let closeSpring = Animation.spring(response: 0.34, dampingFraction: 0.92, blendDuration: 0)

    func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        if value { Feedback.sound("Pop") }
        withAnimation(value ? Self.openSpring : Self.closeSpring) {
            expanded = value
            hoveringClosed = false
            if !value {
                editing = false
                openedByHotkey = false
                shelfDragActive = false
                if page == .volume || page == .brightness || page == .mirror { page = .widgets }
            }
        }
        if !value { showNextPeekIfIdle() }
    }

    /// Opened by ⌃⌥V: stay open until the pointer has visited the island once.
    var openedByHotkey = false

    func toggleClipboardFromHotkey() {
        if expanded && page == .clipboard {
            openedByHotkey = false
            setExpanded(false)
            return
        }
        peekTask?.cancel()
        peek = nil
        withAnimation(Self.openSpring) {
            editing = false
            page = .clipboard
            expanded = true
            openedByHotkey = true
        }
    }

    // MARK: Celebrations (one at a time, short queue)

    var celebration: Celebration?
    @ObservationIgnored private var celebrationQueue: [CelebrationKind] = []
    @ObservationIgnored private var celebrationTask: Task<Void, Never>?
    /// Debug/snapshots: render the celebration at a fixed time.
    var debugFixedTime: Double?
    /// Opponent goal: shake + deflate counter (animated).
    var pillShake: CGFloat = 0
    /// Goal celebration: the slim bar briefly grows taller at the peak.
    var celebrationTall = false

    func celebrate(_ kind: CelebrationKind) {
        guard !AppSettings.shared.prefs.islandHidden else { return }
        if debugFixedTime == nil {
            switch IslandContext.shared.celebration(kind) {
            case .now: break
            case .later: IslandContext.shared.hold(kind); return
            case .never: return
            }
        }
        if celebration != nil || currentPermission != nil {
            if celebrationQueue.count < 3 { celebrationQueue.append(kind) }
            return
        }
        start(kind)
    }

    private func start(_ kind: CelebrationKind) {
        peekTask?.cancel()
        withAnimation(Self.openSpring) {
            peek = nil
            celebration = Celebration(kind: kind)
        }
        if case .cinemaIntro = kind { GlowRegistry.view?.playIntro() }
        if case .cinemaOutro = kind { GlowRegistry.view?.playOutro() }
        switch kind {
        case .teamGoal:
            for i in 0..<3 { DispatchQueue.main.asyncAfter(deadline: .now() + 2.1 + Double(i) * 0.09) { Feedback.haptic(.levelChange) } }
            if AppSettings.shared.prefs.goalSound && IslandContext.shared.soundsAllowed { DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { NSSound(named: "Submarine")?.play() } }
        case .redCard, .whistle: Feedback.haptic(.levelChange); DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Feedback.haptic(.levelChange) }
        default: Feedback.haptic(.generic)
        }
        celebrationTask?.cancel()
        celebrationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind.duration))
            guard !Task.isCancelled, self?.debugFixedTime == nil else { return }   // snapshots hold the frame
            self?.endCelebration()
        }
    }

    func endCelebration() {
        celebrationTask?.cancel()
        withAnimation(Self.closeSpring) { celebration = nil; celebrationTall = false }
        if !celebrationQueue.isEmpty {
            let next = celebrationQueue.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.start(next) }
        } else {
            showNextPeekIfIdle()
        }
    }

    func shakePill() {
        flash(.deny, seconds: 0.9)
        withAnimation(.easeInOut(duration: 1.1)) { pillShake += 1 }
    }

    // MARK: Peeks

    func enqueue(_ p: Peek) {
        guard !AppSettings.shared.prefs.islandHidden else { return }
        switch IslandContext.shared.peek(p) {
        case .now: break
        case .later: IslandContext.shared.hold(p); return
        case .never: return
        }
        peekQueue.append(p)
        if peekQueue.count > 4 { peekQueue.removeFirst(peekQueue.count - 4) }
        showNextPeekIfIdle()
    }

    private func showNextPeekIfIdle() {
        guard peek == nil, !expanded, currentPermission == nil, celebration == nil, !peekQueue.isEmpty else { return }
        let next = peekQueue.removeFirst()
        withAnimation(Self.openSpring) { peek = next }
        if next.actionTitle != nil { Feedback.haptic(.levelChange) }
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.duration))
            guard !Task.isCancelled else { return }
            self?.dismissPeek()
        }
    }

    /// Drops waiting peeks that are no longer true (e.g. an Undo that has expired).
    func dropQueuedPeeks(titled title: String) {
        peekQueue.removeAll { $0.title == title }
    }

    func dismissPeek() {
        guard peek != nil else { return }
        withAnimation(Self.closeSpring) { peek = nil }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            self?.showNextPeekIfIdle()
        }
    }

    // MARK: Claude permissions

    func addPermission(_ r: PermissionRequest) {
        peekTask?.cancel()
        withAnimation(Self.openSpring) {
            peek = nil
            permissions.append(r)
        }
        PermissionHotKeys.update(active: true)
    }

    func removePermission(id: UUID) {
        guard permissions.contains(where: { $0.id == id }) else { return }
        withAnimation(Self.closeSpring) {
            permissions.removeAll { $0.id == id }
        }
        if permissions.isEmpty {
            PermissionHotKeys.update(active: false)
            showNextPeekIfIdle()
        }
    }

    /// When the last answer was given; a second answer within 400 ms is ignored, so a
    /// double-click on Allow can never answer the next card in the queue.
    @ObservationIgnored private var lastAnswerAt: Date?

    /// Hotkeys (⌃⌥Y / ⌃⌥N): answer the card that is on screen.
    func answerCurrent(allow: Bool) {
        guard let r = currentPermission else { return }
        answer(id: r.id, allow: allow)
    }

    /// Answers exactly the request with this id, and only while it is the card on screen and
    /// still waiting. Clicks on a card that already timed out or was answered do nothing.
    func answer(id: UUID, allow: Bool) {
        if let t = lastAnswerAt, Date().timeIntervalSince(t) < 0.4 { return }
        guard let r = currentPermission, r.id == id, !r.isFinished else { return }
        lastAnswerAt = Date()
        r.respond(allow: allow)
        Feedback.haptic(allow ? .levelChange : .generic)
        if !allow { flash(.deny, seconds: 0.9) }
        removePermission(id: r.id)
    }
}
