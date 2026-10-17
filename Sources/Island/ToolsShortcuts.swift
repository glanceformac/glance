import AppKit
import SwiftUI
import Observation

// MARK: feat/productivity - Shortcuts runner and Focus switcher (public tools only: the `shortcuts` CLI)

enum ToolsShell {
    nonisolated static func run(_ exe: String, _ args: [String]) async -> (code: Int32, out: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: (-1, "")); return }
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(data: d, encoding: .utf8) ?? ""))
            }
        }
    }
}

@Observable @MainActor
final class ShortcutsService {
    static let shared = ShortcutsService()
    private(set) var names: [String] = []
    private(set) var loaded = false
    private(set) var running: String?
    private(set) var lastResult: (name: String, ok: Bool)?
    /// Debug/testing: names to use instead of calling `shortcuts list`.
    var fakeNames: [String]?

    func loadIfNeeded(force: Bool = false) {
        guard force || !loaded else { return }
        if let f = fakeNames { names = f; loaded = true; return }
        Task {
            let r = await ToolsShell.run("/usr/bin/shortcuts", ["list"])
            names = r.out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            loaded = true
        }
    }

    func run(_ name: String) {
        guard running == nil else { return }
        running = name
        lastResult = nil
        Task {
            let r = await ToolsShell.run("/usr/bin/shortcuts", ["run", name])
            running = nil
            lastResult = (name, r.code == 0)
            IslandModel.shared.enqueue(Peek(symbol: r.code == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                            title: r.code == 0 ? "Shortcut ran" : "Shortcut failed", subtitle: String(name.prefix(28)),
                                            tint: r.code == 0 ? .green : .orange, duration: 2.5))
        }
    }
}

struct ShortcutsRunnerView: View {
    let theme: Theme
    private let svc = ShortcutsService.shared
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let q = query.lowercased()
        let list = q.isEmpty ? svc.names : svc.names.filter { $0.lowercased().contains(q) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ToolField(theme: theme, placeholder: "Search your Shortcuts, click to run", text: $query, symbol: "bolt.horizontal", focus: $focused) {
                    if let f = list.first { svc.run(f) }
                }
                ToolPill(theme: theme, title: "Open Shortcuts", symbol: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
                }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 5) {
                    ForEach(list, id: \.self) { n in
                        Button { svc.run(n) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: svc.running == n ? "hourglass" : "play.fill").font(.system(size: 9)).foregroundStyle(theme.accent).frame(width: 12)
                                Text(n).font(.system(size: 12)).foregroundStyle(theme.primary).lineLimit(1)
                                Spacer(minLength: 0)
                                if let r = svc.lastResult, r.name == n {
                                    Image(systemName: r.ok ? "checkmark" : "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(r.ok ? .green : .orange)
                                }
                            }
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.card))
                        }.buttonStyle(PressScaleStyle()).disabled(svc.running != nil)
                    }
                }
                if svc.loaded, list.isEmpty {
                    Text(svc.names.isEmpty ? "No shortcuts found. Create one in the Shortcuts app." : "No shortcut matches \"\(query)\"")
                        .font(.system(size: 11)).foregroundStyle(theme.tertiary).padding(14)
                }
            }
            Text("\(svc.names.count) shortcuts · runs exactly as in the Shortcuts app").font(.system(size: 9)).foregroundStyle(theme.tertiary)
        }
        .onAppear { focused = true; svc.loadIfNeeded() }
    }
}

// MARK: Focus

struct FocusSwitcherView: View {
    let theme: Theme
    private let svc = ShortcutsService.shared
    private let focus = FocusMonitor.shared

    private var focusNames: [String] {
        var names = ["do not disturb", "focus", "dnd"]
        if let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/Library/DoNotDisturb/DB/ModeConfigurations.json"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cfgs = ((obj["data"] as? [[String: Any]])?.first?["modeConfigurations"]) as? [String: Any] {
            for (_, v) in cfgs { if let n = ((v as? [String: Any])?["mode"] as? [String: Any])?["name"] as? String { names.append(n.lowercased()) } }
        }
        return names
    }

    var body: some View {
        let names = focusNames
        let matches = svc.names.filter { n in let l = n.lowercased(); return names.contains { l.contains($0) } }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: focus.active != nil ? "moon.fill" : "moon").font(.system(size: 24)).foregroundStyle(focus.active != nil ? Color.indigo : theme.secondary)
                    .frame(width: 44, height: 44).background(Circle().fill(theme.card))
                VStack(alignment: .leading, spacing: 2) {
                    Text(Env.noPermissions ? "Focus status not read in test mode" : (focus.active.map { "\($0) is on" } ?? (focus.available ? "No Focus is on" : "Focus status unavailable")))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.primary)
                    Text(focus.available || Env.noPermissions ? "Read from the Focus database macOS keeps for you. Scheduled Focus modes may not show." :
                            "macOS keeps this in a protected file that Glance cannot read without Full Disk Access. Glance does not ask for it.")
                        .font(.system(size: 10)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                ToolPill(theme: theme, title: "Open Focus settings", symbol: "gearshape") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!)
                    IslandModel.shared.setExpanded(false)
                }
            }
            Text("Switch with a Shortcut").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.tertiary)
            if matches.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("macOS has no public way for an app to switch Focus directly. The supported way is a Shortcut that uses the \"Set Focus\" action.")
                    Text("Make one, name it after the Focus (for example \"Work Focus on\" or \"Do Not Disturb off\"), and it appears here as a button.")
                }
                .font(.system(size: 11)).foregroundStyle(theme.secondary)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card))
                ToolPill(theme: theme, title: "Create in Shortcuts", symbol: "plus") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 5) {
                        ForEach(matches, id: \.self) { n in
                            Button { svc.run(n) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "moon.stars").font(.system(size: 11)).foregroundStyle(.indigo)
                                    Text(n).font(.system(size: 12)).foregroundStyle(theme.primary).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10).frame(height: 32)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.card))
                            }.buttonStyle(PressScaleStyle())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear { svc.loadIfNeeded() }
    }
}
