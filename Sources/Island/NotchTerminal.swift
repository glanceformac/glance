// MARK: feat/claude-dev
// Notch terminal: a single-line command runner in the expanded island.
//  * Runs `/bin/zsh -lc <command>` in the chosen folder, only when you press Return or Run.
//    Nothing ever runs automatically, and it refuses to run while the island is hidden.
//  * The command gets its own process group, so Ctrl-C (or Stop) interrupts the whole pipeline.
//  * stdin is /dev/null: interactive programs (vim, top, ssh prompts) are not supported.
//  * Output is kept in memory only (last 200 KB) and cleared on quit.

import AppKit
import Darwin
import Observation
import SwiftUI

@Observable @MainActor
final class NotchTerminal {
    static let shared = NotchTerminal()

    var input = ""
    private(set) var output = ""
    private(set) var runningCommand: String?
    private(set) var lastStatus: String?
    private(set) var lastOK = true
    private(set) var started: Date?
    var directory: String {
        get { let d = AppSettings.shared.prefs.dev.terminalDirectory; return d.isEmpty ? NSHomeDirectory() : d }
        set { AppSettings.shared.prefs.dev.terminalDirectory = newValue }
    }
    var history: [String] { AppSettings.shared.prefs.dev.terminalHistory }
    @ObservationIgnored var historyIndex: Int?

    @ObservationIgnored private var pid: pid_t = 0
    @ObservationIgnored private var readSource: DispatchSourceRead?
    @ObservationIgnored private var procSource: DispatchSourceProcess?
    @ObservationIgnored private var pending = Data()
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var interruptCount = 0
    private static let maxOutput = 200_000

    var isRunning: Bool { runningCommand != nil }

    /// Why a command can't run right now (nil = it can).
    var blockedReason: String? {
        if AppSettings.shared.prefs.islandHidden { return "The island is hidden, so the terminal will not run commands." }
        if !IslandModel.shared.expanded { return "Open the island to run commands." }
        return nil
    }

    // MARK: Running

    /// Runs the typed command. Only ever called from the Run button or Return in the field.
    func run() {
        let cmd = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !isRunning else { return }
        if let why = blockedReason { lastStatus = why; lastOK = false; return }
        var dir = directory
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue { dir = NSHomeDirectory() }

        var h = history.filter { $0 != cmd }
        h.append(cmd)
        AppSettings.shared.prefs.dev.terminalHistory = Array(h.suffix(50))
        historyIndex = nil
        input = ""
        append("\u{276F} \(cmd)\n")

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { finish(status: "Could not create a pipe", ok: false); return }
        let readFD = fds[0], writeFD = fds[1]

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, writeFD, 1)
        posix_spawn_file_actions_adddup2(&fa, writeFD, 2)
        posix_spawn_file_actions_addclose(&fa, readFD)
        posix_spawn_file_actions_addclose(&fa, writeFD)
        posix_spawn_file_actions_addchdir_np(&fa, dir)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // Own process group (so Ctrl-C reaches every process of the command), default signals.
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t(); sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var none = sigset_t(); sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        env["PAGER"] = "cat"
        env["GIT_PAGER"] = "cat"
        env.removeValue(forKey: "GLANCE_SOCKET_PATH")
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let args = ["/bin/zsh", "-lc", cmd]
        let argv = args.map { strdup($0) } + [nil]
        var child: pid_t = 0
        let rc = posix_spawn(&child, "/bin/zsh", &fa, &attr, argv, envp)
        argv.forEach { free($0) }
        envp.forEach { free($0) }
        posix_spawn_file_actions_destroy(&fa)
        posix_spawnattr_destroy(&attr)
        close(writeFD)
        guard rc == 0 else { close(readFD); finish(status: "Could not start zsh (\(rc))", ok: false); return }

        pid = child
        runningCommand = cmd
        started = Date()
        lastStatus = nil
        interruptCount = 0
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)

        let q = DispatchQueue(label: "island.terminal.read")
        let rs = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: q)
        rs.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(readFD, &buf, buf.count)
            if n > 0 {
                let d = Data(buf[0..<n])
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(d) } }
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                rs.cancel()
            }
        }
        rs.setCancelHandler { close(readFD) }
        readSource = rs
        rs.resume()

        let ps = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        ps.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reap() }
        }
        procSource = ps
        ps.resume()
    }

    /// Ctrl-C / Stop: SIGINT to the process group; a second press sends SIGKILL.
    func interrupt() {
        guard isRunning, pid > 0 else { return }
        interruptCount += 1
        killpg(pid, interruptCount >= 2 ? SIGKILL : SIGINT)
        append(interruptCount >= 2 ? "^C (killed)\n" : "^C\n")
    }

    private func reap() {
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        guard r == pid else { return }
        procSource?.cancel(); procSource = nil
        // Let the last output arrive before the status line.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flush()
                let dur = ClaudeServer.format(duration: Date().timeIntervalSince(self.started ?? Date()))
                let lowBits = status & 0x7f
                if lowBits == 0 {
                    let code = (status >> 8) & 0xff
                    self.finish(status: "exit \(code) · \(dur)", ok: code == 0)
                } else {
                    let sig = lowBits
                    self.finish(status: sig == SIGINT ? "stopped · \(dur)" : "signal \(sig) · \(dur)", ok: false)
                }
            }
        }
    }

    private func finish(status: String, ok: Bool) {
        runningCommand = nil
        pid = 0
        lastStatus = status
        lastOK = ok
        readSource = nil
    }

    // MARK: Output (coalesced to ~10 updates a second)

    private func received(_ d: Data) {
        pending.append(d)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in MainActor.assumeIsolated { self?.flush() } }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        append(Self.stripANSI(text))
    }

    private func append(_ s: String) {
        output += s
        if output.utf8.count > Self.maxOutput {
            output = "…\n" + String(output.suffix(Self.maxOutput * 3 / 4))
        }
    }

    func clear() { output = ""; if !isRunning { lastStatus = nil } }

    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") || s.contains("\r") else { return s }
        var t = s.replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\u{1B}\][^\u{07}]*\u{07}"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        return t.replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: History

    func historyUp() {
        guard !history.isEmpty else { return }
        let i = max(0, (historyIndex ?? history.count) - 1)
        historyIndex = i
        input = history[i]
    }

    func historyDown() {
        guard let i = historyIndex else { return }
        if i + 1 >= history.count { historyIndex = nil; input = "" } else { historyIndex = i + 1; input = history[i + 1] }
    }

    func chooseDirectory() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: directory)
        p.prompt = "Use Folder"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { directory = u.path }
    }

    func terminateOnQuit() { if pid > 0 { killpg(pid, SIGTERM) } }
}

// MARK: - View

struct TerminalPane: View {
    let theme: Theme
    @Bindable private var term = NotchTerminal.shared
    @FocusState private var focused: Bool
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    Button("Choose Folder…") { term.chooseDirectory() }
                    Button("Home") { term.directory = NSHomeDirectory() }
                    let recents = [NSHomeDirectory() + "/Desktop", NSHomeDirectory() + "/Downloads"]
                    ForEach(recents, id: \.self) { d in Button((d as NSString).lastPathComponent) { term.directory = d } }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 10, weight: .semibold))
                        Text(shortPath(term.directory)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(theme.primary)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Capsule().fill(theme.card))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Working folder: \(displayPath(term.directory))")
                .disabled(term.isRunning)

                HStack(spacing: 6) {
                    Text("\u{276F}").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(theme.accent)
                    TextField(term.isRunning ? "Running… Ctrl-C stops it" : "Type a command and press Return", text: $term.input)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.primary)
                        .focused($focused)
                        .onSubmit { term.run(); focused = true }
                        .disabled(term.isRunning)
                }
                .padding(.horizontal, 10).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focused ? theme.accent.opacity(0.6) : theme.cardStroke, lineWidth: 0.8))

                if term.isRunning {
                    pill("Stop", symbol: "stop.fill", tint: Color(red: 1, green: 0.35, blue: 0.3)) { term.interrupt() }
                        .help("Stop (Ctrl-C). Press twice to force.")
                } else {
                    pill("Run", symbol: "play.fill", tint: theme.accent) { term.run() }
                        .disabled(term.input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(term.output.isEmpty ? placeholder : term.output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(term.output.isEmpty ? theme.tertiary : theme.primary.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: term.output) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(theme.dark ? 0.35 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.cardStroke, lineWidth: 0.5))
            HStack(spacing: 8) {
                if term.isRunning, let start = term.started {
                    ProgressView().controlSize(.mini)
                    Text(timerInterval: start...Date.distantFuture, countsDown: false)
                        .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(theme.secondary)
                } else if let s = term.lastStatus {
                    Image(systemName: term.lastOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.system(size: 10)).foregroundStyle(term.lastOK ? .green : Color(red: 1, green: 0.35, blue: 0.3))
                    Text(s).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.secondary).lineLimit(1)
                }
                Spacer()
                Text("zsh -lc · ↑↓ history · no interactive input").font(.system(size: 10)).foregroundStyle(theme.tertiary)
                Button("Clear") { term.clear() }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.secondary)
            }
            .frame(height: 14)
        }
        .onAppear { installMonitor(); DispatchQueue.main.async { focused = true } }
        .onDisappear { removeMonitor() }
    }

    private var placeholder: String { "Output appears here. Commands run only when you press Return." }

    /// "~" or the folder name, so the button stays small.
    private func shortPath(_ p: String) -> String {
        p == NSHomeDirectory() ? "~" : (p as NSString).lastPathComponent
    }

    private func displayPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p == home ? "~" : (p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p)
    }

    private func pill(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11).frame(height: 26)
            .background(Capsule().fill(tint))
        }
        .buttonStyle(PressScaleStyle())
    }

    /// Ctrl-C and ↑/↓ while the terminal is on screen and the island has keyboard focus.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.window is IslandPanel else { return e }
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let ctrlC = mods == .control && e.charactersIgnoringModifiers == "c"
            let plain = mods.subtracting([.function, .numericPad]).isEmpty
            let key = e.keyCode
            let handled: Bool = MainActor.assumeIsolated {
                let t = NotchTerminal.shared
                if ctrlC, t.isRunning { t.interrupt(); return true }
                if plain, !t.isRunning {
                    if key == 126 { t.historyUp(); return true }
                    if key == 125 { t.historyDown(); return true }
                }
                return false
            }
            return handled ? nil : e
        }
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}
