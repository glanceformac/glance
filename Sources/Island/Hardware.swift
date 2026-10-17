import AppKit
import CoreAudio
import AudioToolbox
import Observation

// MARK: - Volume (CoreAudio, change-listener driven)

@Observable @MainActor
final class VolumeControl {
    static let shared = VolumeControl()
    var volume: Float = 0.5
    var muted = false
    var available = false

    @ObservationIgnored private var device = AudioDeviceID(0)
    @ObservationIgnored private var listening: AudioDeviceID = 0

    private static var volAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var defaultAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    func start() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultAddr, .main) { _, _ in
            MainActor.assumeIsolated { VolumeControl.shared.attachDefault() }
        }
        attachDefault()
    }

    private func attachDefault() {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultAddr, 0, nil, &size, &id) == noErr else { return }
        device = id
        available = AudioObjectHasProperty(id, &Self.volAddr)
        if listening != id {
            listening = id
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                MainActor.assumeIsolated { VolumeControl.shared.read() }
            }
            AudioObjectAddPropertyListenerBlock(id, &Self.volAddr, .main, block)
            AudioObjectAddPropertyListenerBlock(id, &Self.muteAddr, .main, block)
        }
        read()
    }

    private func read() {
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &Self.volAddr, 0, nil, &size, &v) == noErr { volume = v }
        var m = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &Self.muteAddr, 0, nil, &size, &m) == noErr { muted = m != 0 }
    }

    func set(_ value: Float) {
        var v = Float32(min(max(value, 0), 1))
        volume = v
        AudioObjectSetPropertyData(device, &Self.volAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if muted && v > 0 { setMuted(false) }
    }

    func setMuted(_ m: Bool) {
        var val = UInt32(m ? 1 : 0)
        muted = m
        AudioObjectSetPropertyData(device, &Self.muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &val)
    }
}

// MARK: - Brightness (DisplayServices private framework; verified working on M1 MacBook Pro)

@Observable @MainActor
final class BrightnessControl {
    static let shared = BrightnessControl()
    var brightness: Float = 0.5
    private(set) var available = false

    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    @ObservationIgnored private var getFn: GetFn?
    @ObservationIgnored private var setFn: SetFn?
    @ObservationIgnored private var timer: Timer?

    private init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let g = dlsym(h, "DisplayServicesGetBrightness"),
              let s = dlsym(h, "DisplayServicesSetBrightness") else { return }
        getFn = unsafeBitCast(g, to: GetFn.self)
        setFn = unsafeBitCast(s, to: SetFn.self)
        var b: Float = 0
        available = getFn?(CGMainDisplayID(), &b) == 0
        if available { brightness = b }
    }

    /// Brightness has no change notification, so refresh slowly only while a dial is visible.
    func setWatching(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on, available else { return }
        let t = Timer(timeInterval: 3, repeats: true) { _ in MainActor.assumeIsolated { BrightnessControl.shared.read() } }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func read() {
        var b: Float = 0
        if getFn?(CGMainDisplayID(), &b) == 0, abs(b - brightness) > 0.005 { brightness = b }
    }

    func set(_ v: Float) {
        let c = min(max(v, 0), 1)
        brightness = c
        _ = setFn?(CGMainDisplayID(), c)
    }
}
