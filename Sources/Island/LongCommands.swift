// MARK: feat/claude-dev
// Long-command islands: a Claude Code Bash call that runs longer than N seconds shows a small
// running capsule inside the closed pill, and a finish peek with its duration and exit status.
// Fed by the glance-hook PreToolUse / PostToolUse / PostToolUseFailure events (see INSTALL-HOOKS.md).
// No timers run unless a command is in flight.

import AppKit
import Observation
import SwiftUI

struct RunningCommand: Identifiable, Equatable {
    let id: String              // tool_use_id (or a generated id)
    let session: String
    let project: String
    let command: String
    var start: Date
    var shown = false           // passed the threshold: visible in the pill
    var waitingForPermission = false
}

@Observable @MainActor
final class LongCommands {
    static let shared = LongCommands()

    private(set) var running: [RunningCommand] = []
    /// The command shown in the pill (oldest visible one).
    var visible: RunningCommand? { running.first { $0.shown && !$0.waitingForPermission } }
    var visibleCount: Int { running.filter { $0.shown && !$0.waitingForPermission }.count }

    @ObservationIgnored private var showTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var permissionFor: [UUID: String] = [:]

    private var threshold: TimeInterval { TimeInterval(max(1, AppSettings.shared.prefs.dev.longCommandSeconds)) }
    private var enabled: Bool { AppSettings.shared.prefs.dev.longCommands }

    // MARK: Hook events

    func pre(_ msg: [String: Any], project: String, session: String) {
        guard enabled, msg["tool_name"] as? String == "Bash" else { return }
        let input = msg["tool_input"] as? [String: Any] ?? [:]
        let cmd = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        // Commands sent to the background return at once; nothing to wait for.
        if (input["run_in_background"] as? Bool) == true { return }
        let id = (msg["tool_use_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        guard !running.contains(where: { $0.id == id }) else { return }
        running.append(RunningCommand(id: id, session: session, project: project, command: cmd, start: Date()))
        if running.count > 8 { cancel(running.removeFirst().id) }
        armShow(id, after: threshold)
    }

    func post(_ msg: [String: Any], failed: Bool, session: String) {
        guard msg["tool_name"] as? String == "Bash" else { return }
        let input = msg["tool_input"] as? [String: Any] ?? [:]
        let cmd = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let id = msg["tool_use_id"] as? String ?? ""
        // Match by tool_use_id; fall back to the same command in the same session.
        guard let idx = running.firstIndex(where: { !id.isEmpty && $0.id == id })
                ?? running.firstIndex(where: { $0.session == session && $0.command == cmd }) else { return }
        let rc = running.remove(at: idx)
        cancel(rc.id)
        let duration = Date().timeIntervalSince(rc.start)
        guard enabled, duration >= threshold else { return }
        var interrupted = false
        if let meta = msg["tool_response_meta"] as? [String: Any] { interrupted = (meta["interrupted"] as? Bool) == true }
        let exit = failed ? Self.exitCode(msg["error"] as? String) : 0
        finished(command: rc.command, project: rc.project, duration: duration, exitCode: exit, interrupted: interrupted)
    }

    /// A permission card for a Bash command: its clock should not run while it waits for you.
    func permissionStarted(request: UUID, session: String, command: String) {
        guard let i = running.lastIndex(where: { $0.session == session && $0.command == command.trimmingCharacters(in: .whitespacesAndNewlines) }) else { return }
        running[i].waitingForPermission = true
        cancel(running[i].id)
        permissionFor[request] = running[i].id
    }

    /// The permission connection closed (answered here, in the terminal, or timed out).
    func permissionEnded(request: UUID, denied: Bool) {
        guard let id = permissionFor.removeValue(forKey: request), let i = running.firstIndex(where: { $0.id == id }) else { return }
        if denied { running.remove(at: i); return }
        running[i].waitingForPermission = false
        running[i].start = Date()
        armShow(id, after: threshold)
    }

    /// The turn ended (Stop) or a new prompt started: anything still "running" never ran
    /// (denied in the terminal) or was lost.
    func sessionIdle(_ session: String) {
        let stale = running.filter { $0.session == session }
        guard !stale.isEmpty else { return }
        stale.forEach { cancel($0.id) }
        withAnimation(.easeOut(duration: 0.2)) { running.removeAll { $0.session == session } }
    }

    func clearAll() {
        running.forEach { cancel($0.id) }
        running = []
    }

    // MARK: Internals

    private func armShow(_ id: String, after: TimeInterval) {
        showTasks[id]?.cancel()
        showTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(after))
            guard !Task.isCancelled, let self, let i = self.running.firstIndex(where: { $0.id == id }) else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.running[i].shown = true }
            self.showTasks[id] = nil
            // Forget a command after 2 hours without a PostToolUse (lost event).
            self.showTasks[id + ".expire"] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(7200))
                guard !Task.isCancelled else { return }
                self?.running.removeAll { $0.id == id }
            }
        }
    }

    private func cancel(_ id: String) {
        showTasks.removeValue(forKey: id)?.cancel()
        showTasks.removeValue(forKey: id + ".expire")?.cancel()
    }

    func finished(command: String, project: String, duration: TimeInterval, exitCode: Int?, interrupted: Bool) {
        let ok = exitCode == 0 && !interrupted
        let status = interrupted ? "stopped" : (exitCode.map { "exit \($0)" } ?? "failed")
        IslandModel.shared.enqueue(Peek(symbol: ok ? "checkmark.circle.fill" : "xmark.octagon.fill",
                                        title: Self.shortCommand(command),
                                        subtitle: "\(ClaudeServer.format(duration: duration)) · \(status)",
                                        tint: ok ? .green : Color(red: 1, green: 0.35, blue: 0.3), duration: 4))
        if !ok { IslandModel.shared.flash(.deny, seconds: 0.9) }
    }

    /// "Exit code 2\n..." -> 2
    static func exitCode(_ error: String?) -> Int? {
        guard let e = error, let r = e.range(of: #"Exit code (\d+)"#, options: .regularExpression) else { return nil }
        return Int(e[r].dropFirst("Exit code ".count))
    }

    /// First word(s) of a command for the pill: "npm run build", "swift test".
    static func shortCommand(_ cmd: String) -> String {
        var first = cmd.split(whereSeparator: \.isNewline).first.map(String.init) ?? cmd
        // Drop a leading "cd somewhere &&".
        if let r = first.range(of: #"^\s*cd\s+[^&;]+(&&|;)\s*"#, options: .regularExpression) { first.removeSubrange(r) }
        let words = first.split(separator: " ").prefix(3).joined(separator: " ")
        return words.count > 26 ? String(words.prefix(25)) + "…" : words
    }
}

/// Small capsule inside the closed pill while a long command runs. It sits at the right edge,
/// within the pill (the island never grows). The clock is a system-updated timer text.
struct LongCommandPillBadge: View {
    let theme: Theme
    private let lc = LongCommands.shared

    var body: some View {
        // Context: hidden while the Prompter runs or the in-pill video controls are showing.
        if let rc = lc.visible, AppSettings.shared.prefs.dev.longCommands,
           IslandContext.shared.current != .prompter, !IslandModel.shared.hoverControls {
            HStack(spacing: 4) {
                Circle().fill(Color.orange).frame(width: 5, height: 5)
                Text(LongCommands.shortCommand(rc.command))
                    .font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: 70, alignment: .leading)
                Text(timerInterval: rc.start...Date.distantFuture, countsDown: false)
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .fixedSize()
                if lc.visibleCount > 1 {
                    Text("+\(lc.visibleCount - 1)").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(Color(white: 0.16)))
            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.55), lineWidth: 0.6))
            .padding(.trailing, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .help("Claude Code is running: \(rc.command)")
            .accessibilityLabel("Command running: \(LongCommands.shortCommand(rc.command))")
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
}
