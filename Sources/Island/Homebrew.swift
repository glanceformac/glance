// MARK: feat/claude-dev
// Homebrew panel: lists `brew outdated --json=v2` (only if /opt/homebrew/bin/brew exists).
// Read-only by default. Upgrades need "Allow upgrades" in Settings AND an explicit confirmation
// for each action (one package, or all). Listing sets HOMEBREW_NO_AUTO_UPDATE so it never
// changes anything; nothing runs on a timer.

import AppKit
import Darwin
import Observation
import SwiftUI

struct BrewPackage: Identifiable, Equatable, Sendable {
    var id: String { (cask ? "cask:" : "") + name }
    let name: String
    let installed: String
    let current: String
    let cask: Bool
    let pinned: Bool
}

@Observable @MainActor
final class Homebrew {
    static let shared = Homebrew()

    /// Test instances may point at a stand-in script (GLANCE_BREW_PATH) so upgrades can be
    /// exercised without touching the real Homebrew.
    nonisolated static var brewPath: String {
        if Env.isolated, let p = ProcessInfo.processInfo.environment["GLANCE_BREW_PATH"], !p.isEmpty { return p }
        return "/opt/homebrew/bin/brew"
    }
    nonisolated static var available: Bool { FileManager.default.isExecutableFile(atPath: brewPath) }

    private(set) var packages: [BrewPackage] = []
    private(set) var loading = false
    private(set) var lastChecked: Date?
    private(set) var error: String?
    /// Waiting for "Upgrade" to be confirmed: a package id, or "*" for all.
    var confirming: String?
    private(set) var upgrading: String?          // package id or "*"
    private(set) var progressLine = ""
    private(set) var log = ""
    private(set) var results: [String: Bool] = [:]  // id -> success
    @ObservationIgnored private var pid: pid_t = 0

    var allowUpgrades: Bool { AppSettings.shared.prefs.dev.brewUpgrades }

    func refresh() {
        guard Self.available, !loading, upgrading == nil else {
            if !Self.available { error = "Homebrew not found at /opt/homebrew/bin/brew" }
            return
        }
        loading = true
        error = nil
        let path = Self.brewPath
        DispatchQueue.global(qos: .utility).async {
            let (status, out) = Self.runCapture(path, ["outdated", "--json=v2"])
            let parsed = Self.parse(out)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let b = Homebrew.shared
                    b.loading = false
                    b.lastChecked = Date()
                    if let p = parsed { b.packages = p } else { b.error = status == 0 ? "Could not read brew output" : "brew outdated failed (exit \(status))" }
                }
            }
        }
    }

    nonisolated static func parse(_ data: Data) -> [BrewPackage]? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var out: [BrewPackage] = []
        for (key, cask) in [("formulae", false), ("casks", true)] {
            for f in o[key] as? [[String: Any]] ?? [] {
                guard let name = f["name"] as? String else { continue }
                let inst = (f["installed_versions"] as? [String])?.last ?? (f["installed_versions"] as? String) ?? "?"
                out.append(BrewPackage(name: name, installed: inst, current: f["current_version"] as? String ?? "?",
                                       cask: cask, pinned: (f["pinned"] as? Bool) == true))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Upgrades (explicit confirmation only)

    func askConfirm(_ id: String) { guard allowUpgrades, upgrading == nil else { return }; confirming = id }
    func cancelConfirm() { confirming = nil }

    /// Runs the confirmed upgrade. Called only from the confirmation button.
    func confirmUpgrade() {
        guard allowUpgrades, let target = confirming, upgrading == nil, Self.available else { return }
        guard !AppSettings.shared.prefs.islandHidden else { error = "The island is hidden."; return }
        confirming = nil
        var args = ["upgrade"]
        if target != "*", let p = packages.first(where: { $0.id == target }) {
            if p.cask { args.append("--cask") }
            args.append(p.name)
        }
        upgrading = target
        progressLine = "Starting brew \(args.joined(separator: " "))…"
        log = ""
        let path = Self.brewPath
        Self.spawnStreaming(path, args, onLine: { line in
            MainActor.assumeIsolated {
                let b = Homebrew.shared
                b.progressLine = line
                b.log += line + "\n"
                if b.log.utf8.count > 60_000 { b.log = String(b.log.suffix(45_000)) }
            }
        }, onStart: { pid in
            MainActor.assumeIsolated { Homebrew.shared.pid = pid }
        }, onExit: { status in
            MainActor.assumeIsolated {
                let b = Homebrew.shared
                b.pid = 0
                let ok = status == 0
                if target == "*" { for p in b.packages where !p.pinned { b.results[p.id] = ok } } else { b.results[target] = ok }
                b.progressLine = ok ? "Upgrade finished" : "Upgrade failed (exit \(status))"
                b.upgrading = nil
                IslandModel.shared.enqueue(Peek(symbol: ok ? "checkmark.circle.fill" : "xmark.octagon.fill",
                                                title: target == "*" ? "Homebrew upgrade" : "Upgraded \(target.replacingOccurrences(of: "cask:", with: ""))",
                                                subtitle: ok ? "done" : "failed", tint: ok ? .green : .red, duration: 3))
                b.refresh()
            }
        })
    }

    func stopUpgrade() { if pid > 0 { killpg(pid, SIGINT) } }

    // MARK: Process helpers

    nonisolated private static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        env["NONINTERACTIVE"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.removeValue(forKey: "GLANCE_SOCKET_PATH")
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Runs and captures stdout (stderr discarded). Blocking: call off the main thread.
    nonisolated static func runCapture(_ path: String, _ args: [String]) -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env: [String: String] = [:]
        for kv in environment() { if let i = kv.firstIndex(of: "=") { env[String(kv[..<i])] = String(kv[kv.index(after: i)...]) } }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, Data()) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    /// Spawns in its own process group and streams lines (stdout + stderr) to the main queue.
    nonisolated static func spawnStreaming(_ path: String, _ args: [String], onLine: @escaping @Sendable (String) -> Void,
                                           onStart: @escaping @Sendable (pid_t) -> Void, onExit: @escaping @Sendable (Int32) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { DispatchQueue.main.async { onExit(-1) }; return }
            var fa: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&fa)
            posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&fa, fds[1], 1)
            posix_spawn_file_actions_adddup2(&fa, fds[1], 2)
            var attr: posix_spawnattr_t?
            posix_spawnattr_init(&attr)
            posix_spawnattr_setpgroup(&attr, 0)
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
            let argv = ([path] + args).map { strdup($0) } + [nil]
            let envp = environment().map { strdup($0) } + [nil]
            var child: pid_t = 0
            let rc = posix_spawn(&child, path, &fa, &attr, argv, envp)
            argv.forEach { free($0) }; envp.forEach { free($0) }
            posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr)
            close(fds[1])
            guard rc == 0 else { close(fds[0]); DispatchQueue.main.async { onExit(-1) }; return }
            DispatchQueue.main.async { onStart(child) }
            let fh = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
            var carry = Data()
            var lastSent = Date.distantPast
            while true {
                let d = fh.availableData
                if d.isEmpty { break }
                carry.append(d)
                while let nl = carry.firstIndex(of: 0x0A) {
                    let line = String(decoding: carry[carry.startIndex..<nl], as: UTF8.self)
                    carry.removeSubrange(carry.startIndex...nl)
                    let clean = NotchTerminalText.strip(line).trimmingCharacters(in: .whitespaces)
                    guard !clean.isEmpty else { continue }
                    // At most ~8 UI updates a second.
                    if Date().timeIntervalSince(lastSent) > 0.12 || clean.hasPrefix("==>") {
                        lastSent = Date()
                        DispatchQueue.main.async { onLine(clean) }
                    }
                }
            }
            var status: Int32 = 0
            waitpid(child, &status, 0)
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            DispatchQueue.main.async { onExit(code) }
        }
    }
}

enum NotchTerminalText {
    nonisolated static func strip(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        return s.replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }
}

// MARK: - View

struct BrewPane: View {
    let theme: Theme
    private let brew = Homebrew.shared

    var body: some View {
        VStack(spacing: 8) {
            header
            if !Homebrew.available {
                empty("Homebrew is not installed at /opt/homebrew/bin/brew.")
            } else if brew.packages.isEmpty {
                empty(brew.loading ? "Checking for outdated packages…" : (brew.error ?? (brew.lastChecked == nil ? "Press Check to list outdated packages." : "Everything is up to date.")))
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(brew.packages) { p in row(p) }
                    }
                    .padding(.vertical, 2)
                }
            }
            footer
        }
        .onAppear { if brew.lastChecked == nil || Date().timeIntervalSince(brew.lastChecked!) > 600 { brew.refresh() } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "mug").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent)
            Text(brew.packages.isEmpty ? "Homebrew" : "\(brew.packages.count) outdated")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primary)
            if let d = brew.lastChecked {
                Text("checked \(d.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundStyle(theme.tertiary)
            }
            Spacer()
            if brew.allowUpgrades && !brew.packages.isEmpty {
                if brew.confirming == "*" {
                    confirmRow(text: "Upgrade all \(brew.packages.count)?")
                } else {
                    small("Upgrade All", symbol: "arrow.up.circle", filled: false) { brew.askConfirm("*") }
                        .disabled(brew.upgrading != nil)
                }
            }
            small(brew.loading ? "Checking…" : "Check", symbol: "arrow.clockwise", filled: false) { brew.refresh() }
                .disabled(brew.loading || brew.upgrading != nil)
        }
    }

    private func row(_ p: BrewPackage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: p.cask ? "app.dashed" : "shippingbox").font(.system(size: 10)).foregroundStyle(theme.secondary).frame(width: 14)
            Text(p.name).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.primary).lineLimit(1)
            if p.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(theme.tertiary).help("Pinned") }
            Spacer(minLength: 6)
            Text("\(p.installed) → \(p.current)").font(.system(size: 11).monospacedDigit()).foregroundStyle(theme.secondary).lineLimit(1)
            if let ok = brew.results[p.id] {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill").font(.system(size: 11)).foregroundStyle(ok ? .green : .red)
            }
            if brew.upgrading == p.id || (brew.upgrading == "*") {
                ProgressView().controlSize(.mini)
            } else if brew.allowUpgrades && !p.pinned {
                if brew.confirming == p.id {
                    confirmRow(text: "Upgrade?")
                } else {
                    small("Upgrade", symbol: nil, filled: false) { brew.askConfirm(p.id) }
                        .disabled(brew.upgrading != nil)
                }
            }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.card))
    }

    private func confirmRow(text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.primary)
            small("Cancel", symbol: nil, filled: false) { brew.cancelConfirm() }
            small("Upgrade", symbol: nil, filled: true) { brew.confirmUpgrade() }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if brew.upgrading != nil {
                ProgressView().controlSize(.mini)
                Text(brew.progressLine).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.secondary).lineLimit(1).truncationMode(.tail)
                Spacer()
                Button("Stop") { brew.stopUpgrade() }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(.red)
            } else if !brew.progressLine.isEmpty {
                Text(brew.progressLine).font(.system(size: 10)).foregroundStyle(theme.secondary).lineLimit(1)
                Spacer()
            } else {
                Text(brew.allowUpgrades ? "Upgrades ask for confirmation first." : "Read-only. Turn on upgrades in Settings › Developer.")
                    .font(.system(size: 10)).foregroundStyle(theme.tertiary)
                Spacer()
            }
        }
        .frame(height: 14)
    }

    private func empty(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(theme.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.opacity(0.6)))
    }

    private func small(_ title: String, symbol: String?, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(filled ? theme.onAccent : theme.primary)
            .padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(filled ? theme.accent : theme.card.opacity(1.8)))
        }
        .buttonStyle(PressScaleStyle())
    }
}
