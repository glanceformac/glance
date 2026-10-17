import AppKit
import SwiftUI
import CoreMedia
import CoreMediaIO
import CoreAudio
import Darwin
import Observation

// MARK: - Camera / microphone guard
//
// Camera: CoreMediaIO "device is running somewhere" property listeners (no permission, no frames).
// Microphone: CoreAudio process objects (macOS 14.2+): which processes are running input, with
// their bundle ID and PID, so the app name is exact. Falls back to the device-level
// "running somewhere" flag on input-only devices.
// Camera has no public per-process API, so the app name is a best guess (see `guess`).
// Everything is event driven; nothing polls.

@Observable @MainActor
final class CameraGuard {
    static let shared = CameraGuard()

    private(set) var cameraInUse = false
    private(set) var micInUse = false
    private(set) var cameraApp: String?
    private(set) var micApp: String?
    /// True when either is live: other features can use this to stay quiet (no sounds, no celebrations).
    var inUse: Bool { cameraInUse || micInUse }

    @ObservationIgnored private var started = false
    @ObservationIgnored private var audioProcessBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    @ObservationIgnored private var audioDeviceBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    @ObservationIgnored private var sysListListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var recheck: Task<Void, Never>?

    // Simulation for tests: nil = use the real hardware state.
    @ObservationIgnored var simCamera: Bool?
    @ObservationIgnored var simMic: Bool?
    @ObservationIgnored var simCameraApp: String?
    @ObservationIgnored var simMicApp: String?

    func start() {
        guard !started else { return }
        started = true
        trackContextCamera()
        attachMic()
        attachDeviceChanges()
        evaluate()   // always from the live hardware state, never a cached one
    }

    func stop() {
        guard started else { return }
        started = false
        detachAudio()
        verifyTimer?.invalidate(); verifyTimer = nil
        cameraInUse = false; micInUse = false; cameraApp = nil; micApp = nil
    }

    // MARK: Camera (state comes from IslandContext, which already listens to CoreMediaIO)

    private func trackContextCamera() {
        guard started else { return }
        withObservationTracking({ _ = IslandContext.shared.cameraInUse }, onChange: { [weak self] in
            Task { @MainActor in self?.trackContextCamera(); self?.scheduleEvaluate() }
        })
    }

    /// Read-only camera probe used by the debug tools.
    nonisolated static func cameraDeviceCount() -> Int {
        var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                          mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                          mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &a, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<CMIODeviceID>.size
    }

    // MARK: Microphone (CoreAudio)

    fileprivate func attachMic() {
        var sys = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if sysListListener == nil {
            let b: AudioObjectPropertyListenerBlock = { _, _ in
                MainActor.assumeIsolated { CameraGuard.shared.attachProcesses(); CameraGuard.shared.scheduleEvaluate() }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &sys, .main, b) == noErr { sysListListener = b }
        }
        attachProcesses()
        // Input-only devices (built-in mic, USB mics): device-level flag as a fallback.
        var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        // Every input device (also ones with outputs), re-attached when devices or the default input change.
        for d in SoundCenter.devices(input: true) where audioDeviceBlocks[d.id] == nil {
            let b: AudioObjectPropertyListenerBlock = { _, _ in
                MainActor.assumeIsolated { CameraGuard.shared.scheduleEvaluate() }
            }
            if AudioObjectAddPropertyListenerBlock(d.id, &running, .main, b) == noErr { audioDeviceBlocks[d.id] = b }
        }
    }

    @ObservationIgnored private var defaultInputListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var devicesListener: AudioObjectPropertyListenerBlock?
    private func attachDeviceChanges() {
        for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let b: AudioObjectPropertyListenerBlock = { _, _ in
                MainActor.assumeIsolated { CameraGuard.shared.attachMic(); CameraGuard.shared.scheduleEvaluate() }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, b) == noErr {
                if sel == kAudioHardwarePropertyDefaultInputDevice { defaultInputListener = b } else { devicesListener = b }
            }
        }
    }

    // MARK: Safety net: while a dot shows, re-read the real state every 3 s (cheap property reads)

    @ObservationIgnored private var verifyTimer: Timer?
    private func updateVerifyTimer() {
        let showing = cameraInUse || micInUse
        if showing, verifyTimer == nil, simMic == nil, simCamera == nil {
            let t = Timer(timeInterval: 3, repeats: true) { _ in
                MainActor.assumeIsolated {
                    IslandContext.shared.refreshCamera()
                    CameraGuard.shared.evaluate()
                }
            }
            t.tolerance = 0.5
            RunLoop.main.add(t, forMode: .common)
            verifyTimer = t
        } else if !showing {
            verifyTimer?.invalidate(); verifyTimer = nil
        }
    }

    private func attachProcesses() {
        var inAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let current = Set(Self.audioProcesses())
        for (id, b) in audioProcessBlocks where !current.contains(id) {
            AudioObjectRemovePropertyListenerBlock(id, &inAddr, .main, b)
            audioProcessBlocks[id] = nil
        }
        for id in current where audioProcessBlocks[id] == nil {
            let b: AudioObjectPropertyListenerBlock = { _, _ in
                MainActor.assumeIsolated { CameraGuard.shared.scheduleEvaluate() }
            }
            if AudioObjectAddPropertyListenerBlock(id, &inAddr, .main, b) == noErr { audioProcessBlocks[id] = b }
        }
    }

    private func detachAudio() {
        var inAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        for (id, b) in audioProcessBlocks { AudioObjectRemovePropertyListenerBlock(id, &inAddr, .main, b) }
        audioProcessBlocks.removeAll()
        var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        for (id, b) in audioDeviceBlocks { AudioObjectRemovePropertyListenerBlock(id, &running, .main, b) }
        audioDeviceBlocks.removeAll()
        var sys = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if let b = sysListListener { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &sys, .main, b); sysListListener = nil }
    }

    nonisolated static func audioProcesses() -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Processes (other than Glance) that are recording right now: (pid, bundle id).
    nonisolated static func micClients() -> [(pid: pid_t, bundle: String?)] {
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [(pid_t, String?)] = []
        for p in audioProcesses() {
            var running = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(p, &running, 0, nil, &sz, &v) == noErr, v != 0 else { continue }
            var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            sz = UInt32(MemoryLayout<pid_t>.size)
            _ = AudioObjectGetPropertyData(p, &pidAddr, 0, nil, &sz, &pid)
            if pid == me || Self.isSystemProcess(pid: pid) { continue }   // Siri voice trigger (corespeechd) etc.
            var bAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var cf: Unmanaged<CFString>?
            sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let st = AudioObjectGetPropertyData(p, &bAddr, 0, nil, &sz, &cf)
            let bundle = st == noErr ? cf?.takeRetainedValue() as String? : nil
            out.append((pid, bundle))
        }
        return out
    }

    /// System daemons that keep the input "running" at very low power (e.g. "Hey Siri"): not mic use.
    nonisolated static func isSystemProcess(pid: pid_t) -> Bool {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        let path = String(cString: buf)
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/")
    }

    /// Any input device actually running (the hardware truth used together with the process list).
    nonisolated static func anyInputDeviceRunning() -> Bool {
        var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        for d in SoundCenter.devices(input: true) {
            var v: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(d.id, &running, 0, nil, &sz, &v) == noErr, v != 0 { return true }
        }
        return false
    }

    nonisolated static func appName(pid: pid_t, bundle: String?) -> String? {
        // Helper processes (Chrome Helper, Zoom helper) map to their parent app by bundle prefix.
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
        if let b = bundle {
            if let app = NSWorkspace.shared.runningApplications.first(where: { b.hasPrefix($0.bundleIdentifier ?? "\u{0}") && $0.activationPolicy == .regular }),
               let n = app.localizedName { return n }
            return b.split(separator: ".").last.map(String.init)
        }
        return nil
    }

    // MARK: Evaluate

    private func scheduleEvaluate() {
        recheck?.cancel()
        recheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    /// Re-read the hardware state and raise a peek on an off -> on change.
    func evaluate() {
        let prefs = AppSettings.shared.prefs
        let camNow = simCamera ?? IslandContext.shared.cameraInUse
        let clients = simMic == nil ? Self.micClients() : []
        // In use only if an input device is really running AND a non-system app is recording.
        let micNow = simMic ?? ((!clients.isEmpty && Self.anyInputDeviceRunning()) || Self.inputOnlyDeviceRunning())
        let wasCam = cameraInUse, wasMic = micInUse

        if camNow && !wasCam {
            cameraApp = simCameraApp ?? guess(clientsAlsoOnMic: clients)
        }
        if !camNow { cameraApp = nil }
        if micNow && !wasMic {
            micApp = simMicApp ?? clients.compactMap { Self.appName(pid: $0.pid, bundle: $0.bundle) }.first
        }
        if !micNow { micApp = nil }
        if camNow != wasCam || (micNow && prefs.cameraGuardMic) != wasMic {
            NSLog("Glance guard: camera=%@ mic=%@ (clients %d)", camNow ? "on" : "off", micNow ? "on" : "off", clients.count)
        }
        cameraInUse = camNow
        micInUse = micNow && prefs.cameraGuardMic
        updateVerifyTimer()

        let ownCamera = Mirror.shared.state == .running || Mirror.shared.state == .starting
        if camNow && !wasCam && !ownCamera {
            peek(camera: true, app: cameraApp)
        }
        if micNow && prefs.cameraGuardMic && !wasMic {
            peek(camera: false, app: micApp)
        }
    }

    /// Fallback only when the process list is unavailable (it also lists Glance's own use, which must not alarm).
    nonisolated static func inputOnlyDeviceRunning() -> Bool {
        guard audioProcesses().isEmpty else { return false }
        var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        for d in SoundCenter.devices(input: true) where !d.hasOutput {
            var v: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(d.id, &running, 0, nil, &sz, &v) == noErr, v != 0 {
                return true
            }
        }
        return false
    }

    /// Camera has no per-process API. Best guess: an app that is also recording audio, else the
    /// frontmost regular app. Marked as a guess in the peek.
    private func guess(clientsAlsoOnMic clients: [(pid: pid_t, bundle: String?)]) -> String? {
        if let n = clients.compactMap({ Self.appName(pid: $0.pid, bundle: $0.bundle) }).first { return n }
        if let f = NSWorkspace.shared.frontmostApplication, f.activationPolicy == .regular,
           f.processIdentifier != ProcessInfo.processInfo.processIdentifier { return f.localizedName }
        return nil
    }

    private func peek(camera: Bool, app: String?) {
        guard AppSettings.shared.prefs.cameraGuard else { return }
        let tint: Color = camera ? .green : .orange
        var p = Peek(symbol: camera ? "video.fill" : "mic.fill",
                     title: camera ? "Camera on" : (app == nil ? "Microphone on" : "Mic on"),   // short when the app name follows (UAT: "Micr...Teams")
                     subtitle: app, tint: tint, duration: 4)
        if let app, let icon = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == app })?.icon {
            icon.size = NSSize(width: 64, height: 64)
            p.icon = icon
        }
        IslandModel.shared.enqueue(p)
        Feedback.haptic(.levelChange)
    }

    // MARK: Test hooks

    func simulate(camera: Bool?, mic: Bool?, cameraApp: String? = nil, micApp: String? = nil) {
        if let camera { simCamera = camera; simCameraApp = cameraApp }
        if let mic { simMic = mic; simMicApp = micApp }
        evaluate()
    }
}

// MARK: - Pill indicator dots (inside the closed pill's shape)

struct GuardDots: View {
    private let guardian = CameraGuard.shared
    var body: some View {
        let cam = guardian.cameraInUse && AppSettings.shared.prefs.cameraGuard
        let mic = guardian.micInUse && AppSettings.shared.prefs.cameraGuard
        HStack(spacing: 3) {
            if mic { Circle().fill(Color.orange).frame(width: 5, height: 5).shadow(color: .orange.opacity(0.8), radius: 2)
                .accessibilityLabel("Microphone in use\(guardian.micApp.map { " by " + $0 } ?? "")") }
            if cam { Circle().fill(Color.green).frame(width: 5, height: 5).shadow(color: .green.opacity(0.8), radius: 2)
                .accessibilityLabel("Camera in use\(guardian.cameraApp.map { " by " + $0 } ?? "")") }
        }
        .padding(.top, 4).padding(.trailing, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
        .accessibilityHidden(!(cam || mic))
        .accessibilityLabel(cam && mic ? "Camera and microphone in use" : (cam ? "Camera in use" : "Microphone in use"))
    }
}
