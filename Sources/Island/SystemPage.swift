import AppKit
import SwiftUI
import Observation

// MARK: - The System tab: Screenshots, Monitor, Tools, Rings, Stocks

enum SystemTab: String, CaseIterable, Identifiable {
    case shots, monitor, tools, rings, stocks
    var id: String { rawValue }
    var title: String {
        switch self { case .shots: "Screenshots"; case .monitor: "Monitor"; case .tools: "Tools"; case .rings: "Rings"; case .stocks: "Stocks" }
    }
    var symbol: String {
        switch self {
        case .shots: "camera.viewfinder"
        case .monitor: "gauge.with.dots.needle.50percent"
        case .tools: "wrench.and.screwdriver"
        case .rings: "circle.circle"
        case .stocks: "chart.line.uptrend.xyaxis"
        }
    }
}

@Observable @MainActor
final class SystemPageState {
    static let shared = SystemPageState()
    var tab: SystemTab = .shots
}

struct SystemPage: View {
    let theme: Theme
    private let state = SystemPageState.shared
    @Namespace private var ns

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                ForEach(SystemTab.allCases) { t in
                    let on = state.tab == t
                    Button {
                        withAnimation(IslandModel.openSpring) { state.tab = t }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: t.symbol).font(.system(size: 10, weight: .medium))
                            Text(t.title).font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(on ? theme.primary : theme.secondary)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background {
                            if on {
                                Capsule().fill(theme.accent.opacity(theme.dark ? 0.26 : 0.16))
                                    .overlay(Capsule().strokeBorder(theme.accent.opacity(0.45), lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "systab", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t.title)
                }
                Spacer(minLength: 0)
            }
            Group {
                switch state.tab {
                case .shots: ScreenshotsView(theme: theme)
                case .monitor: MonitorView(theme: theme)
                case .tools: ToolsView(theme: theme)
                case .rings: RingsView(theme: theme)
                case .stocks: StocksView(theme: theme)
                }
            }
            .transition(.opacity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Settings section (referenced by one line in SettingsView)

struct SystemMediaSettings: View {
    @Bindable private var settings = AppSettings.shared
    @State private var symbols = AppSettings.shared.prefs.stockSymbols

    var body: some View {
        Section("System & Media") {
            Toggle("Live Activities (capsules beside the pill)", isOn: $settings.prefs.liveActivities)
            Toggle("Camera and microphone guard", isOn: $settings.prefs.cameraGuard)
            if settings.prefs.cameraGuard {
                Toggle("Include the microphone", isOn: $settings.prefs.cameraGuardMic)
                Text("A green dot (camera) or orange dot (microphone) shows on the pill, and a peek names the app when it can. Camera names are a best guess; macOS has no public per-app camera list.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("AirPods and Bluetooth: peek when connected (with battery)", isOn: $settings.prefs.btConnectPeek)
            Toggle("Caps Lock HUD (needs Input Monitoring)", isOn: $settings.prefs.capsLockHUD)
            Toggle("Volume and brightness in the island (best effort)", isOn: $settings.prefs.hudReplace)
            if settings.prefs.hudReplace {
                Text("macOS may still show its own volume and brightness HUD; Glance cannot hide it without private APIs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Screenshot shelf", isOn: $settings.prefs.screenshotShelf)
            if settings.prefs.screenshotShelf {
                Toggle("Read text in screenshots (on this Mac) so they are searchable", isOn: $settings.prefs.screenshotOCR)
                Toggle("Peek when a screenshot is saved", isOn: $settings.prefs.screenshotPeek)
                Text("Watching: \(ScreenshotShelf.resolveFolder().path). Glance never moves or deletes your screenshots.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Toggle("Clipboard extras: 1 to 9 quick paste, colour swatches, plain text, clean links", isOn: $settings.prefs.clipExtras)
            Toggle("Window snap zones (needs Accessibility)", isOn: $settings.prefs.snapZones)
            if settings.prefs.snapZones && !AXIsProcessTrusted() {
                Text("Allow Glance in System Settings, Privacy & Security, Accessibility, then toggle this again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("System monitor (samples every 2 s only while open)", isOn: $settings.prefs.systemMonitor)
            Toggle("Activity rings: keystroke count, cursor distance, active minutes", isOn: $settings.prefs.activityRings)
            if settings.prefs.activityRings {
                Text("Counts only, never which keys. Keystrokes need Input Monitoring; Glance asks only now that this is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Stocks ticker (Yahoo Finance, free, may be delayed)", isOn: $settings.prefs.stocksEnabled)
            if settings.prefs.stocksEnabled {
                TextField("Symbols, separated by commas", text: $symbols)
                    .onSubmit { settings.prefs.stockSymbols = symbols; StocksService.shared.refresh() }
            }
            Toggle("Desktop pet", isOn: $settings.prefs.deskPet)
        }
    }
}
