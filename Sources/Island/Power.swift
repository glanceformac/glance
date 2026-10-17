import AppKit
import IOKit.ps
import Observation

/// Battery saver: on battery or in Low Power Mode (setting "Battery saver: automatic", default
/// on), Cinema caps its rates and pauses the glow rotation. Event driven (no polling).
@Observable @MainActor
final class Power {
    static let shared = Power()
    private(set) var onBattery = false
    private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var obs: NSObjectProtocol?

    var saving: Bool { AppSettings.shared.prefs.batterySaverAuto && (onBattery || lowPower) }
    /// Colour update interval: 5 Hz (also on battery; the render server interpolates between).
    var colourInterval: Double { 0.2 }
    var barsRate: Double { saving ? 15 : 24 }   // equaliser targets per second (the render server tweens at 60 fps)

    func start() {
        refresh()
        let ctx = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        if let src = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Power.shared.refresh() } }
        }, ctx)?.takeRetainedValue() {
            source = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        obs = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Power.shared.refresh() }
        }
    }

    func refresh() {
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            onBattery = type == kIOPSBatteryPowerValue
        }
        ClaudeConnection.maxRate = barsRate
    }
}
