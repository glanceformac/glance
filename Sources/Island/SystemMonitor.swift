import AppKit
import SwiftUI
import IOKit
import Darwin
import Observation

// MARK: - System monitor
//
// CPU, memory, disk, network and battery health. Sampled every 2 s ONLY while the monitor is on
// screen (`setVisible(true)` from the view); a hidden monitor costs nothing. Everything is public
// (Mach host statistics, getifaddrs, IOKit AppleSmartBattery). No SMC, no root. The only
// temperature shown is the battery's own sensor.

@Observable @MainActor
final class SystemMonitor {
    static let shared = SystemMonitor()
    static let historyLength = 40

    private(set) var cpu: Double = 0           // 0...1
    private(set) var memory: Double = 0        // used / total
    private(set) var memoryUsedGB: Double = 0
    private(set) var memoryTotalGB: Double = 0
    private(set) var diskFreeGB: Double = 0
    private(set) var diskTotalGB: Double = 0
    private(set) var netDown: Double = 0       // bytes / s
    private(set) var netUp: Double = 0
    private(set) var cpuHistory: [Double] = []
    private(set) var memHistory: [Double] = []
    private(set) var downHistory: [Double] = []
    private(set) var upHistory: [Double] = []
    private(set) var battery: BatteryInfo?
    private(set) var samples = 0

    struct BatteryInfo: Equatable {
        var healthPercent: Int?
        var cycles: Int?
        var designCycles: Int?
        var temperatureC: Double?
        var percent: Int?
        var charging: Bool
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCPU: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?
    @ObservationIgnored private var lastNet: (down: UInt64, up: UInt64, at: Date)?
    @ObservationIgnored private var visibleCount = 0

    var isSampling: Bool { timer != nil }

    /// Views call this on appear / disappear. The timer only runs while at least one is visible.
    func setVisible(_ on: Bool) {
        visibleCount = max(0, visibleCount + (on ? 1 : -1))
        if visibleCount > 0 && AppSettings.shared.prefs.systemMonitor { startTimer() } else { stopTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { SystemMonitor.shared.sample() } }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate(); timer = nil
        lastCPU = nil; lastNet = nil
    }

    func sample() {
        sampleCPU()
        sampleMemory()
        sampleNet()
        if samples % 5 == 0 { sampleDisk(); battery = Self.readBattery() }
        samples += 1
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        if arr.isEmpty { arr = Array(repeating: v, count: Self.historyLength - 1) }   // flat line until history builds
        arr.append(v)
        if arr.count > Self.historyLength { arr.removeFirst(arr.count - Self.historyLength) }
    }

    // MARK: CPU

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return }
        let cur = (user: info.cpu_ticks.0, sys: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { lastCPU = cur }
        guard let last = lastCPU else { return }
        let du = Double(cur.user &- last.user), ds = Double(cur.sys &- last.sys), di = Double(cur.idle &- last.idle), dn = Double(cur.nice &- last.nice)
        let total = du + ds + di + dn
        guard total > 0 else { return }
        cpu = (du + ds + dn) / total
        push(&cpuHistory, cpu)
    }

    // MARK: Memory

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        // Same breakdown Activity Monitor uses: app memory + wired + compressed.
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let used = (max(app, 0) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        memoryUsedGB = used / 1_073_741_824
        memoryTotalGB = total / 1_073_741_824
        memory = min(used / total, 1)
        push(&memHistory, memory)
    }

    // MARK: Disk

    private func sampleDisk() {
        let u = URL(fileURLWithPath: "/")
        guard let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) else { return }
        diskFreeGB = Double(v.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000
        diskTotalGB = Double(v.volumeTotalCapacity ?? 0) / 1_000_000_000
    }

    // MARK: Network

    nonisolated static func netBytes() -> (down: UInt64, up: UInt64) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (0, 0) }
        defer { freeifaddrs(ifap) }
        var down: UInt64 = 0, up: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let name = String(cString: cur.pointee.ifa_name)
            if let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en"),
               let data = cur.pointee.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                down += UInt64(d.ifi_ibytes); up += UInt64(d.ifi_obytes)
            }
            p = cur.pointee.ifa_next
        }
        return (down, up)
    }

    private func sampleNet() {
        let now = Date()
        let b = Self.netBytes()
        defer { lastNet = (b.down, b.up, now) }
        guard let l = lastNet else { return }
        let dt = now.timeIntervalSince(l.at)
        guard dt > 0.2 else { return }
        netDown = Double(b.down &- l.down) / dt
        netUp = Double(b.up &- l.up) / dt
        push(&downHistory, netDown)
        push(&upHistory, netUp)
    }

    // MARK: Battery (IOKit AppleSmartBattery)

    nonisolated static func readBattery() -> BatteryInfo? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
        func int(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        let design = int("DesignCapacity")
        let full = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity")
        var health: Int?
        if let design, let full, design > 0 { health = min(100, Int((Double(full) / Double(design) * 100).rounded())) }
        return BatteryInfo(healthPercent: health, cycles: int("CycleCount"), designCycles: int("DesignCycleCount9C"),
                           temperatureC: int("Temperature").map { Double($0) / 100 }, percent: int("StateOfCharge") ?? int("CurrentCapacity"),
                           charging: (d["IsCharging"] as? Bool) ?? false)
    }
}

// MARK: - View

struct MonitorView: View {
    let theme: Theme
    private let mon = SystemMonitor.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                tile("CPU", String(format: "%.0f%%", mon.cpu * 100), sub: "all cores", history: mon.cpuHistory, max: 1, tint: theme.accent)
                tile("Memory", String(format: "%.1f GB", mon.memoryUsedGB), sub: String(format: "of %.0f GB", mon.memoryTotalGB),
                     history: mon.memHistory, max: 1, tint: .purple)
                tile("Network", "↓ " + rate(mon.netDown), sub: "↑ " + rate(mon.netUp),
                     history: mon.downHistory, max: Swift.max(mon.downHistory.max() ?? 1, 50_000), tint: .green)
            }
            HStack(spacing: 8) {
                tile("Disk free", String(format: "%.0f GB", mon.diskFreeGB), sub: String(format: "of %.0f GB", mon.diskTotalGB), history: [], max: 1, tint: .orange,
                     bar: mon.diskTotalGB > 0 ? 1 - mon.diskFreeGB / mon.diskTotalGB : nil)
                    .frame(height: 82)
                batteryTile.frame(height: 82)
            }
        }
        .onAppear { mon.setVisible(true) }
        .onDisappear { mon.setVisible(false) }
    }

    private var batteryTile: some View {
        let b = mon.battery
        return VStack(alignment: .leading, spacing: 3) {
            title("Battery health")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(b?.healthPercent.map { "\($0)%" } ?? "n/a")
                    .font(.system(size: 18, weight: .semibold).monospacedDigit()).foregroundStyle(theme.primary)
                Text(b?.cycles.map { "\($0) cycles" } ?? "")
                    .font(.system(size: 11)).foregroundStyle(theme.secondary)
            }
            Text(batterySub(b)).font(.system(size: 10)).foregroundStyle(theme.tertiary).lineLimit(1)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.card))
        .frame(maxWidth: .infinity)
    }

    private func batterySub(_ b: SystemMonitor.BatteryInfo?) -> String {
        guard let b else { return "No battery" }
        var parts: [String] = []
        if let t = b.temperatureC { parts.append(String(format: "Battery %.0f°C", t)) }
        if let dc = b.designCycles, let c = b.cycles { parts.append("rated \(dc)") ; _ = c }
        return parts.joined(separator: "  ·  ")
    }

    private func title(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 9.5, weight: .bold)).foregroundStyle(theme.tertiary)
    }

    private func tile(_ name: String, _ value: String, sub: String, history: [Double], max: Double, tint: Color, bar: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            title(name)
            Text(value).font(.system(size: 18, weight: .semibold).monospacedDigit()).foregroundStyle(theme.primary).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(theme.secondary).lineLimit(1)
            if let bar {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.card.opacity(1.6))
                        Capsule().fill(tint).frame(width: g.size.width * bar)
                    }
                }
                .frame(height: 6)
            } else {
                Sparkline(values: history, maxValue: max, tint: tint).frame(height: 22)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.card))
    }

    private func rate(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f MB/s", bps / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0f KB/s", bps / 1_000) }
        return String(format: "%.0f B/s", bps)
    }
}

struct Sparkline: View {
    let values: [Double]
    let maxValue: Double
    let tint: Color
    var body: some View {
        GeometryReader { g in
            let n = SystemMonitor.historyLength
            let step = g.size.width / CGFloat(n - 1)
            let offset = n - values.count
            let pts = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i + offset) * step, y: g.size.height * (1 - CGFloat(min(v / Swift.max(maxValue, 0.0001), 1))))
            }
            ZStack {
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: CGPoint(x: f.x, y: g.size.height)); p.addLine(to: f)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height)); p.closeSubpath()
                }.fill(tint.opacity(0.18))
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f); pts.dropFirst().forEach { p.addLine(to: $0) }
                }.stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
