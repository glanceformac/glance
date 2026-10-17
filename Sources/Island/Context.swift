import AppKit
import CoreMediaIO
import Observation

/// "What is useful when": one place that decides which features may speak up right now, so
/// Cinema, the Prompter, meetings and peeks don't clash. Everything here is event-driven
/// (no polling): camera listeners from CoreMediaIO, the calendar's own refresh, Cinema state.
@Observable @MainActor
final class IslandContext {
    static let shared = IslandContext()

    enum Kind: String, CaseIterable, Identifiable {
        case normal, cinema, fullScreenVideo, prompter, meeting
        var id: String { rawValue }
        var title: String {
            switch self {
            case .normal: "Normal"
            case .cinema: "Watching a video (Cinema)"
            case .fullScreenVideo: "Full-screen video"
            case .prompter: "Prompter running"
            case .meeting: "In a meeting"
            }
        }
    }

    private(set) var cameraInUse = false
    /// Celebrations held back (e.g. during a film) and played when it pauses or ends.
    @ObservationIgnored private var deferredCelebrations: [CelebrationKind] = []
    @ObservationIgnored private var deferredPeeks: [Peek] = []

    /// The detected context (strongest first), or the user's override from Settings.
    var current: Kind {
        let o = AppSettings.shared.prefs.contextOverride
        if o != "auto", let k = Kind(rawValue: o) { return k }
        return detected
    }
    var detected: Kind {
        if Prompter.shared.running { return .prompter }
        let c = ChromeAmbilight.shared
        if c.engaged && c.fullscreen { return .fullScreenVideo }
        if c.engaged { return .cinema }
        if cameraInUse || CalendarService.shared.eventNow { return .meeting }
        return .normal
    }
    var rulesOn: Bool { AppSettings.shared.prefs.contextRules }

    // MARK: Rules

    enum Verdict { case now, later, never }

    func celebration(_ k: CelebrationKind) -> Verdict {
        guard rulesOn else { return .now }
        let goal: Bool = { if case .teamGoal = k { return true }; return false }()
        switch current {
        case .normal: return .now
        case .cinema, .fullScreenVideo:
            if k.isCinemaCA { return .now }
            return goal ? .now : .later                 // goals always; the rest after the film pauses/ends
        case .prompter: return .later
        case .meeting:
            if k.isCinemaCA { return .now }
            return .later                                 // no fanfare in a meeting (played afterwards)
        }
    }

    func peek(_ p: Peek) -> Verdict {
        guard rulesOn else { return .now }
        switch current {
        case .normal, .meeting: return .now
        case .cinema: return .now                         // peeks are already tiny, inside the pill
        case .fullScreenVideo, .prompter: return .later
        }
    }

    /// Sounds (goal horn, chimes) stay quiet in meetings and while prompting.
    var soundsAllowed: Bool { !rulesOn || (current != .meeting && current != .prompter) }
    /// The Prompter isn't offered while a film plays (it would cover it).
    var prompterAllowed: Bool { !rulesOn || (current != .cinema && current != .fullScreenVideo) }
    /// While prompting: Cinema off, no equaliser, approvals only as a small amber dot.
    var cinemaAllowed: Bool { !rulesOn || !Prompter.shared.running }
    var approvalsMinimal: Bool { rulesOn && current == .prompter }

    func hold(_ k: CelebrationKind) {
        if GitCelebrations.shared.absorb(k) { return }   // MARK: wip/cinema-h (git: one collapsed tally)
        if deferredCelebrations.count < 3 { deferredCelebrations.append(k) }
    }
    func hold(_ p: Peek) { deferredPeeks.append(p); if deferredPeeks.count > 4 { deferredPeeks.removeFirst() } }

    /// Called when the context may have changed (Cinema paused/ended, Prompter stopped, ...).
    func reevaluate() {
        GitCelebrations.shared.flush()                   // MARK: wip/cinema-h
        guard !deferredCelebrations.isEmpty || !deferredPeeks.isEmpty else { return }
        let m = IslandModel.shared
        let cs = deferredCelebrations; deferredCelebrations = []
        for k in cs { m.celebrate(k) }                    // re-checked; held again if still not allowed
        let ps = deferredPeeks; deferredPeeks = []
        for p in ps { m.enqueue(p) }
    }

    // MARK: Camera in use (any app), without asking for camera access

    @ObservationIgnored private var watched: [CMIOObjectID] = []

    func start() {
        watchPrompter()
        startCamera()
    }

    /// Follows Prompter.running without touching Prompter.swift (owned by feat/prompter):
    /// when it stops, held peeks/celebrations play and Cinema may resume.
    private func watchPrompter() {
        withObservationTracking { _ = Prompter.shared.running } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let ctx = IslandContext.shared
                    if !Prompter.shared.running {
                        IslandModel.shared.revealPermissions = false
                        ctx.reevaluate()
                    }
                    ChromeAmbilight.shared.transitionCheck()
                    ctx.watchPrompter()
                }
            }
        }
    }

    private func startCamera() {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0, size > 0 else { return }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == 0 else { return }
        for id in ids {
            var a = Self.runningAddress
            _ = CMIOObjectAddPropertyListenerBlock(id, &a, DispatchQueue.main) { _, _ in
                MainActor.assumeIsolated { IslandContext.shared.refreshCamera() }
            }
            watched.append(id)
        }
        refreshCamera()
    }

    private static var runningAddress: CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
    }

    func refreshCamera() {
        var any = false
        for id in watched {
            var a = Self.runningAddress
            var v: UInt32 = 0, used: UInt32 = 0
            if CMIOObjectGetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &v) == 0, v != 0 { any = true }
        }
        // Glance's own Mirror uses the camera too; that isn't a meeting.
        if Mirror.shared.state == .running || Mirror.shared.state == .starting { any = false }
        if any != cameraInUse { cameraInUse = any; reevaluate() }
    }
}
