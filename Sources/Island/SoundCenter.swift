import AppKit
import SwiftUI
import CoreAudio
import Observation

// MARK: - Sound: device pickers, Bluetooth connect peek (+ battery), volume / brightness HUD, Caps Lock HUD
//
// All public CoreAudio. No per-app volume. Bluetooth battery comes from `system_profiler
// SPBluetoothDataType -json` (a documented system tool, no private API, no Bluetooth permission);
// if the device reports no battery, only the connect peek is shown.

struct AudioDev: Identifiable, Equatable {
    var id: AudioDeviceID
    var name: String
    var uid: String
    var hasInput: Bool
    var hasOutput: Bool
    var bluetooth: Bool
}

@Observable @MainActor
final class SoundCenter {
    static let shared = SoundCenter()

    private(set) var outputs: [AudioDev] = []
    private(set) var inputs: [AudioDev] = []
    private(set) var defaultOutput: AudioDeviceID = 0
    private(set) var defaultInput: AudioDeviceID = 0

    @ObservationIgnored private var started = false
    @ObservationIgnored private var knownUIDs: Set<String>? = nil
    @ObservationIgnored private var listBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var defOutBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var defInBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var keyMonitors: [Any] = []
    @ObservationIgnored private var capsLast: Bool?
    @ObservationIgnored private var hudPeekID: UUID?
    @ObservationIgnored private var lastHUD = Date.distantPast
    @ObservationIgnored private var lastVolume: Float = -1
    @ObservationIgnored private var observingVolume = false

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        refresh(announce: false)
        var devs = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dOut = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dIn = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let b1: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { SoundCenter.shared.refresh(announce: true) } }
        let b2: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { SoundCenter.shared.refresh(announce: false) } }
        listBlock = b1; defOutBlock = b2; defInBlock = b2
        AudioObjectAddPropertyListenerBlock(sys, &devs, .main, b1)
        AudioObjectAddPropertyListenerBlock(sys, &dOut, .main, b2)
        AudioObjectAddPropertyListenerBlock(sys, &dIn, .main, b2)
        applyPrefs()
    }

    func stop() {
        guard started else { return }
        started = false
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var devs = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dOut = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dIn = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if let b = listBlock { AudioObjectRemovePropertyListenerBlock(sys, &devs, .main, b) }
        if let b = defOutBlock { AudioObjectRemovePropertyListenerBlock(sys, &dOut, .main, b); AudioObjectRemovePropertyListenerBlock(sys, &dIn, .main, b) }
        listBlock = nil; defOutBlock = nil; defInBlock = nil
        removeKeyMonitors()
    }

    /// Re-evaluate prefs (HUD replacement, Caps Lock) after a settings change.
    func applyPrefs() {
        guard started else { return }
        let p = AppSettings.shared.prefs
        removeKeyMonitors()
        if p.capsLockHUD || p.hudReplace { installKeyMonitors(caps: p.capsLockHUD, media: p.hudReplace) }
        if p.hudReplace { observeVolume() }
    }

    // MARK: Devices

    func refresh(announce: Bool) {
        let ins = Self.devices(input: true)
        let outs = Self.devices(input: false)
        inputs = ins
        outputs = outs
        defaultOutput = Self.defaultDevice(input: false)
        defaultInput = Self.defaultDevice(input: true)
        let all = Set((ins + outs).map(\.uid))
        defer { knownUIDs = all }
        guard announce, let known = knownUIDs else { return }
        let added = (outs + ins).filter { !known.contains($0.uid) && $0.bluetooth }
        var seen = Set<String>()
        for d in added where seen.insert(d.uid).inserted { bluetoothConnected(d) }
    }

    nonisolated static func devices(input: Bool) -> [AudioDev] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        var out: [AudioDev] = []
        for id in ids {
            let hasIn = channels(id, scope: kAudioDevicePropertyScopeInput) > 0
            let hasOut = channels(id, scope: kAudioDevicePropertyScopeOutput) > 0
            guard input ? hasIn : hasOut else { continue }
            let name = string(id, kAudioObjectPropertyName) ?? "Device"
            if name.hasPrefix("CADefaultDeviceAggregate") { continue }
            let transport = u32(id, kAudioDevicePropertyTransportType)
            let bt = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
            out.append(AudioDev(id: id, name: name, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)", hasInput: hasIn, hasOutput: hasOut, bluetooth: bt))
        }
        return out
    }

    nonisolated static func defaultDevice(input: Bool) -> AudioDeviceID {
        var a = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    func setDefault(_ dev: AudioDev, input: Bool) {
        var a = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = dev.id
        let st = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if st == noErr { if input { defaultInput = dev.id } else { defaultOutput = dev.id } }
    }

    nonisolated private static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    nonisolated private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &cf) == noErr else { return nil }
        return cf?.takeRetainedValue() as String?
    }

    nonisolated private static func u32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
        return v
    }

    // MARK: Bluetooth connect peek + battery

    private func bluetoothConnected(_ d: AudioDev) {
        guard AppSettings.shared.prefs.btConnectPeek else { return }
        let name = d.name
        Task.detached(priority: .utility) {
            let battery = Self.bluetoothBattery(named: name)
            await MainActor.run { SoundCenter.shared.showConnectPeek(name: name, battery: battery) }
        }
    }

    func showConnectPeek(name: String, battery: String?) {
        let short = Self.shortName(name)
        let sym = name.localizedCaseInsensitiveContains("pro") && name.localizedCaseInsensitiveContains("airpods") ? "airpodspro"
            : (name.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones")
        IslandModel.shared.enqueue(Peek(symbol: sym, title: "Connected", subtitle: battery.map { "\(short) · \($0)" } ?? short, tint: .white, duration: 3.2))
        Feedback.haptic(.levelChange)
    }

    /// "Sam’s AirPods Pro" -> "AirPods Pro".
    static func shortName(_ n: String) -> String {
        for sep in ["’s ", "'s "] {
            if let r = n.range(of: sep) { return String(n[r.upperBound...]) }
        }
        return n
    }

    /// Battery for a connected Bluetooth device, as a short string like "L 80  R 82  Case 90", or nil.
    nonisolated static func bluetoothBattery(named name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseBattery(json: data, name: name)
    }

    nonisolated static func parseBattery(json: Data, name: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let arr = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        for ctl in arr {
            for entry in (ctl["device_connected"] as? [[String: Any]]) ?? [] {
                for (n, props) in entry where n == name || n.replacingOccurrences(of: "’", with: "'") == name.replacingOccurrences(of: "’", with: "'") {
                    guard let d = props as? [String: Any] else { continue }
                    func pct(_ k: String) -> String? { (d[k] as? String).map { $0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces) } }
                    var parts: [String] = []
                    if let l = pct("device_batteryLevelLeft") { parts.append("L \(l)") }
                    if let r = pct("device_batteryLevelRight") { parts.append("R \(r)") }
                    if let c = pct("device_batteryLevelCase") { parts.append("Case \(c)") }
                    if parts.isEmpty, let m = pct("device_batteryLevelMain") { parts.append("\(m)%") }
                    return parts.isEmpty ? nil : parts.joined(separator: "  ")
                }
            }
        }
        return nil
    }

    // MARK: Volume / brightness / Caps Lock HUD

    private func observeVolume() {
        guard !observingVolume else { return }
        observingVolume = true
        lastVolume = VolumeControl.shared.volume
        trackVolume()
    }

    private func trackVolume() {
        withObservationTracking({ _ = VolumeControl.shared.volume; _ = VolumeControl.shared.muted }, onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started else { self?.observingVolume = false; return }
                self.volumeChanged()
                if AppSettings.shared.prefs.hudReplace { self.trackVolume() } else { self.observingVolume = false }
            }
        })
    }

    private func volumeChanged() {
        let v = VolumeControl.shared
        guard AppSettings.shared.prefs.hudReplace, abs(v.volume - lastVolume) > 0.001 || v.muted else { lastVolume = v.volume; return }
        lastVolume = v.volume
        // The island's own slider is already on screen.
        guard !IslandModel.shared.expanded else { return }
        let sym = v.muted || v.volume == 0 ? "speaker.slash.fill" : (v.volume < 0.33 ? "speaker.wave.1.fill" : (v.volume < 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
        showHUD(symbol: sym, title: v.muted ? "Muted" : "Volume", value: Double(v.volume))
    }

    func showHUD(symbol: String, title: String, value: Double) {
        let m = IslandModel.shared
        let text = "\(Int((value * 100).rounded()))%"
        if let id = hudPeekID, m.peek?.id == id {
            m.peek?.subtitle = text
            m.peek?.symbol = symbol
            return
        }
        let p = Peek(symbol: symbol, title: title, subtitle: text, tint: .white, duration: 1.8)
        hudPeekID = p.id
        m.enqueue(p)
    }

    private func installKeyMonitors(caps: Bool, media: Bool) {
        var mask: NSEvent.EventTypeMask = []
        if caps { mask.insert(.flagsChanged) }
        if media { mask.insert(.systemDefined) }
        guard !mask.isEmpty else { return }
        if caps, !Env.noPermissions, !Env.isolated, !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        capsLast = NSEvent.modifierFlags.contains(.capsLock)
        let handler: (NSEvent) -> Void = { e in
            MainActor.assumeIsolated { SoundCenter.shared.handleKey(e) }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { keyMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in handler(e); return e }) { keyMonitors.append(l) }
    }

    private func removeKeyMonitors() {
        keyMonitors.forEach { NSEvent.removeMonitor($0) }
        keyMonitors.removeAll()
    }

    func handleKey(_ e: NSEvent) {
        let p = AppSettings.shared.prefs
        if e.type == .flagsChanged, p.capsLockHUD {
            let on = e.modifierFlags.contains(.capsLock)
            if capsLast != on { capsLast = on; capsLockChanged(on) }
        } else if e.type == .systemDefined, e.subtype.rawValue == 8, p.hudReplace {
            let code = Int((e.data1 & 0xFFFF0000) >> 16)
            let down = ((e.data1 & 0xFF00) >> 8) == 0xA
            // 2 / 3 = brightness up / down. Volume is handled by the CoreAudio listener.
            if down, code == 2 || code == 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    MainActor.assumeIsolated {
                        BrightnessControl.shared.read()
                        guard !IslandModel.shared.expanded else { return }
                        SoundCenter.shared.showHUD(symbol: "sun.max.fill", title: "Brightness", value: Double(BrightnessControl.shared.brightness))
                    }
                }
            }
        }
    }

    func capsLockChanged(_ on: Bool) {
        IslandModel.shared.enqueue(Peek(symbol: on ? "capslock.fill" : "capslock", title: "Caps Lock", subtitle: on ? "On" : "Off",
                                        tint: on ? .orange : .white, duration: 1.6))
    }
}

// MARK: - Sound page (opens from the speaker icon)

struct SoundPage: View {
    let theme: Theme
    private let vol = VolumeControl.shared
    private let sound = SoundCenter.shared

    var body: some View {
        let value = Double(vol.volume)
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { vol.setMuted(!vol.muted) } label: {
                    Image(systemName: vol.muted || value == 0 ? "speaker.slash.fill" : (value < 0.33 ? "speaker.wave.1.fill" : (value < 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")))
                        .font(.system(size: 16)).foregroundStyle(theme.primary).frame(width: 26)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(vol.muted ? "Unmute" : "Mute")
                FatSlider(value: value, theme: theme) { vol.set(Float($0)) }
                    .frame(height: 20)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(theme.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            HStack(alignment: .top, spacing: 10) {
                DeviceColumn(theme: theme, title: "Output", symbol: "speaker.wave.2", devices: sound.outputs, current: sound.defaultOutput) {
                    sound.setDefault($0, input: false)
                }
                DeviceColumn(theme: theme, title: "Input", symbol: "mic", devices: sound.inputs, current: sound.defaultInput) {
                    sound.setDefault($0, input: true)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { sound.refresh(announce: false) }
    }
}

struct DeviceColumn: View {
    let theme: Theme
    let title: String
    let symbol: String
    let devices: [AudioDev]
    let current: AudioDeviceID
    let pick: (AudioDev) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Text(title.uppercased()).font(.system(size: 9.5, weight: .bold))
            }
            .foregroundStyle(theme.tertiary)
            .padding(.horizontal, 8)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(devices) { d in
                        DeviceRow(theme: theme, device: d, selected: d.id == current) { pick(d) }
                    }
                    if devices.isEmpty {
                        Text("No devices").font(.system(size: 11)).foregroundStyle(theme.tertiary).padding(8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card))
    }
}

struct DeviceRow: View {
    let theme: Theme
    let device: AudioDev
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11)).foregroundStyle(selected ? theme.accent : theme.tertiary)
                Text(device.name).font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(theme.primary).lineLimit(1)
                Spacer(minLength: 0)
                if device.bluetooth { Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 9)).foregroundStyle(theme.tertiary) }
            }
            .padding(.horizontal, 8).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.card.opacity(hover ? 1.5 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("\(device.name)\(selected ? ", selected" : "")")
    }
}
