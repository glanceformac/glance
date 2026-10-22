import AppKit
import Darwin

/// One pending Claude Code permission request. The hook helper is blocked on
/// the socket until we answer or close the connection.
final class PermissionRequest: Identifiable {
    let id = UUID()
    let toolName: String
    let project: String
    let summary: String      // full text shown to the user, never truncated
    let detail: String?      // optional secondary text (e.g. Bash description)
    let received = Date()
    /// Claude Code session, and the subagent that asked ("" for the main agent): its shadow clone waves.
    var session = ""
    var agentID = ""
    fileprivate weak var connection: ClaudeConnection?
    private var answered = false
    /// True once answered, handed back to the terminal (timed out) or abandoned.
    @MainActor var isFinished: Bool { answered }

    init(toolName: String, project: String, summary: String, detail: String?, connection: ClaudeConnection) {
        self.toolName = toolName
        self.project = project
        self.summary = summary
        self.detail = detail
        self.connection = connection
    }

    @MainActor func respond(allow: Bool) {
        guard !answered else { return }
        answered = true
        if !allow { LongCommands.shared.permissionEnded(request: id, denied: true) } // MARK: feat/claude-dev
        connection?.reply(["decision": allow ? "allow" : "deny"])
    }

    /// Closes the connection without a decision, so Claude Code asks in the terminal.
    @MainActor func abandon() {
        guard !answered else { return }
        answered = true
        connection?.close()
    }
}

/// A connection from `glance-hook`. Reads one JSON line.
final class ClaudeConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var gotMessage = false
    /// Chrome host keeps one connection open and streams many JSON lines.
    private var streaming = false
    private var closed = false
    private let onMessage: @Sendable ([String: Any], ClaudeConnection) -> Void
    private let onClose: @Sendable (ClaudeConnection) -> Void
    private static let maxBytes = 8 * 1024 * 1024

    init(fd: Int32, queue: DispatchQueue,
         onMessage: @escaping @Sendable ([String: Any], ClaudeConnection) -> Void,
         onClose: @escaping @Sendable (ClaudeConnection) -> Void) {
        self.fd = fd
        self.queue = queue
        self.onMessage = onMessage
        self.onClose = onClose
    }

    func start() {
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in self?.readAvailable() }
        s.setCancelHandler { [fd] in Darwin.close(fd) }
        source = s
        s.resume()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 {
            if n == 0 || (errno != EAGAIN && errno != EINTR) { closeOnQueue() }
            return
        }
        guard !gotMessage || streaming else { return } // one-shot connections: ignore anything after the first line
        buffer.append(contentsOf: chunk[0..<n])
        if buffer.count > Self.maxBytes { closeOnQueue(); return }
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if gotMessage && !streaming { break }
            let first = !gotMessage
            gotMessage = true
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                if !streaming { closeOnQueue(); return }
                continue
            }
            if first, obj["island_stream"] as? String == "chrome" { streaming = true; continue }
            if streaming {
                coalesce(obj)
            } else {
                onMessage(obj, self)
            }
        }
    }

    func reply(_ obj: [String: Any]) {
        queue.async { [self] in
            guard !closed, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let w = write(fd, raw.baseAddress! + off, raw.count - off)
                    if w <= 0 { break }
                    off += w
                }
            }
            closeOnQueue()
        }
    }

    func close() { queue.async { [self] in closeOnQueue() } }

    // Chrome stream coalescing: state changes are delivered at once; everything else is merged and
    // handed to the main thread at most ~12 times a second (10 on battery saver).
    private var pending: [String: Any]?
    private var lastState = ""
    private var flushScheduled = false
    nonisolated(unsafe) static var maxRate: Double = 24

    private func coalesce(_ obj: [String: Any]) {
        let state = obj["state"] as? String ?? lastState
        let urgent = (obj["type"] as? String) == "result" || state != lastState
        if pending == nil { pending = obj } else { pending!.merge(obj) { _, new in new } }
        lastState = state
        if urgent { flush(); return }
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 1.0 / Self.maxRate) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard let msg = pending else { return }
        pending = nil
        let box = ChromeBox(msg)
        DispatchQueue.main.async { MainActor.assumeIsolated { ChromeAmbilight.shared.receive(box.value, link: self) } }
    }

    /// Streaming connections only: send a line without closing (Glance -> Chrome commands).
    func sendLine(_ obj: [String: Any]) {
        queue.async { [self] in
            guard !closed, streaming, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { raw in _ = write(fd, raw.baseAddress!, raw.count) }
        }
    }

    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        onClose(self)
    }
}

/// Unix-domain socket server in ~/Library/Application Support/Glance (0700 dir, 0600 socket).
/// Never listens on a network port.
@MainActor
final class ClaudeServer {
    static let shared = ClaudeServer()
    private let queue = DispatchQueue(label: "island.claude.socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: ClaudeConnection] = [:]
    private var pending: [ObjectIdentifier: UUID] = [:]
    private var sessionStart: [String: Date] = [:]
    private var filesChanged: [String: Set<String>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]

    static var directory: URL { Env.supportDir }   // private folder in isolated test mode
    static var socketPath: String { Env.testSocket ?? directory.appendingPathComponent("glance.sock").path }

    /// Glance gives up a little before the helper's own 58 s deadline.
    static let answerWindow: TimeInterval = 56

    func start() {
        guard listenFD < 0 else { return }
        let dir = Self.directory.path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        let path = Self.socketPath
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("Glance: socket() failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let oldMask = umask(0o177)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard ok == 0 else { NSLog("Glance: bind failed \(errno)"); Darwin.close(fd); return }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { Darwin.close(fd); return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let q = queue
        src.setEventHandler { ClaudeServer.acceptLoop(listenFD: fd, queue: q) }
        acceptSource = src
        src.resume()
    }

    func stop() {
        acceptSource?.cancel()
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        unlink(Self.socketPath)
        for r in IslandModel.shared.permissions { r.abandon() }
    }
}

extension ClaudeServer {
    /// Accept loop body. Kept separate so it runs off the main thread.
    nonisolated fileprivate static func acceptLoop(listenFD: Int32, queue: DispatchQueue) {
        while true {
            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 { return }
            // Only accept connections from our own user.
            var uid: uid_t = 0, gid: gid_t = 0
            if getpeereid(cfd, &uid, &gid) != 0 || uid != getuid() {
                Darwin.close(cfd)
                continue
            }
            var one: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(cfd, F_SETFL, fcntl(cfd, F_GETFL) | O_NONBLOCK)
            let conn = ClaudeConnection(fd: cfd, queue: queue, onMessage: { msg, c in
                let box = MessageBox(msg)
                DispatchQueue.main.async { MainActor.assumeIsolated { ClaudeServer.shared.handle(box.value, from: c) } }
            }, onClose: { c in
                DispatchQueue.main.async { MainActor.assumeIsolated { ClaudeServer.shared.connectionClosed(c) } }
            })
            DispatchQueue.main.async { MainActor.assumeIsolated { ClaudeServer.shared.register(conn) } }
            conn.start()
        }
    }
}

final class ChromeBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ v: [String: Any]) { value = v }
}

private final class MessageBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ v: [String: Any]) { value = v }
}

extension ClaudeServer {
    fileprivate func register(_ c: ClaudeConnection) {
        connections[ObjectIdentifier(c)] = c
    }

    fileprivate func connectionClosed(_ c: ClaudeConnection) {
        let key = ObjectIdentifier(c)
        connections[key] = nil
        ChromeAmbilight.shared.linkClosed(c)
        if let id = pending.removeValue(forKey: key) {
            LongCommands.shared.permissionEnded(request: id, denied: false) // MARK: feat/claude-dev
            timeouts.removeValue(forKey: id)?.cancel()
            IslandModel.shared.removePermission(id: id)
        }
    }

    fileprivate func handle(_ msg: [String: Any], from c: ClaudeConnection) {
        // Hidden island: no decision, so Claude Code asks in the terminal straight away.
        guard AppSettings.shared.prefs.claudeIntegration, !AppSettings.shared.prefs.islandHidden else { c.close(); return }
        let event = msg["hook_event_name"] as? String ?? ""
        let cwd = msg["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "Claude Code" : (cwd as NSString).lastPathComponent
        let session = msg["session_id"] as? String ?? ""
        CharacterEngine.shared.claude(event: event, session: session, msg: msg) // MARK: wip/character

        // A Stop from inside a subagent is not the end of the turn (no Done peek).
        if event == "Stop", !(msg["agent_id"] as? String ?? "").isEmpty { c.close(); return }

        switch event {
        case "PermissionRequest":
            let tool = msg["tool_name"] as? String ?? "Tool"
            let input = msg["tool_input"] as? [String: Any] ?? [:]
            let (summary, detail) = Self.describe(tool: tool, input: input)
            let req = PermissionRequest(toolName: tool, project: project, summary: summary, detail: detail, connection: c)
            req.session = session; req.agentID = msg["agent_id"] as? String ?? "" // MARK: wip/character
            pending[ObjectIdentifier(c)] = req.id
            if tool == "Bash" { LongCommands.shared.permissionStarted(request: req.id, session: session, command: summary) } // MARK: feat/claude-dev
            IslandModel.shared.addPermission(req)
            timeouts[req.id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.answerWindow))
                guard !Task.isCancelled else { return }
                // No answer: hand the decision back to the terminal prompt.
                req.abandon()
                IslandModel.shared.removePermission(id: req.id)
                self?.timeouts[req.id] = nil
            }
        case "IslandActivity": // MARK: feat/system-media (Live Activities socket API)
            ActivityHub.handle(msg)
            c.close()
        case "IslandDebug": // MARK: feat/system-media (isolated test instances only)
            if Env.isolated, let cmd = msg["cmd"] as? String { SystemMediaDebug.run(cmd) }
            c.close()
        case "UserPromptSubmit":
            ActivityHub.claudeStarted(session: session, project: project) // MARK: feat/system-media
            if !session.isEmpty { sessionStart[session] = Date(); filesChanged[session] = [] }
            LongCommands.shared.sessionIdle(session) // MARK: feat/claude-dev
            c.close()
        case "PreToolUse": // MARK: feat/claude-dev
            LongCommands.shared.pre(msg, project: project, session: session)
            c.close()
        case "PostToolUse", "PostToolUseFailure":
            ActivityHub.claudeTouched(session: session) // MARK: feat/system-media
            LongCommands.shared.post(msg, failed: event == "PostToolUseFailure", session: session) // MARK: feat/claude-dev
            handleToolEvent(msg, event: event, project: project, session: session)
            c.close()
        case "Stop":
            ActivityHub.claudeStopped(session: session) // MARK: feat/system-media
            LongCommands.shared.sessionIdle(session); ClaudeUsage.shared.turnEnded() // MARK: feat/claude-dev
            var parts: [String] = []
            let files = filesChanged.removeValue(forKey: session)?.count ?? 0
            if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s") changed") }
            if let start = sessionStart.removeValue(forKey: session) {
                parts.append(Self.format(duration: Date().timeIntervalSince(start)))
            }
            if AppSettings.shared.prefs.celebrations {
                IslandModel.shared.celebrate(.claudeDone(project: project, detail: parts.joined(separator: " · ")))
            } else {
                IslandModel.shared.enqueue(Peek(symbol: "checkmark.circle.fill", title: "Done", subtitle: ([project] + parts).joined(separator: "  ·  "),
                                                tint: .green, duration: 3.5, prominent: true))
                IslandModel.shared.flash(.done, seconds: 1.4)
            }
            if IslandContext.shared.soundsAllowed { NSSound(named: "Glass")?.play() }
            c.close()
        case "Notification":
            let type = msg["notification_type"] as? String ?? ""
            // permission_prompt is already covered by the PermissionRequest card.
            if type != "permission_prompt" {
                let text = msg["message"] as? String ?? "Claude needs your attention"
                IslandModel.shared.enqueue(Peek(symbol: "sparkle", title: text, subtitle: project,
                                                tint: Color(red: 0.85, green: 0.47, blue: 0.34), duration: 3))
            }
            c.close()
        default:
            c.close()
        }
    }

    /// Files changed (for the Done celebration), commits, pushes and deploys.
    private func handleToolEvent(_ msg: [String: Any], event: String, project: String, session: String) {
        let tool = msg["tool_name"] as? String ?? ""
        if ProcessInfo.processInfo.arguments.contains("--debug") { NSLog("Glance tool event \(event) \(tool)") }
        let input = msg["tool_input"] as? [String: Any] ?? [:]
        if event == "PostToolUse", ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool),
           let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String), !session.isEmpty {
            filesChanged[session, default: []].insert(path)
            return
        }
        guard tool == "Bash", AppSettings.shared.prefs.deployCelebrations, AppSettings.shared.prefs.celebrations else { return }
        let cmd = (input["command"] as? String ?? "")
        let kind: (ok: String, fail: String)?
        if cmd.range(of: #"\bgit\s+push\b"#, options: .regularExpression) != nil { kind = ("PUSHED", "PUSH FAILED") }
        else if cmd.range(of: #"\bgh\s+pr\s+create\b"#, options: .regularExpression) != nil { kind = ("PR OPENED", "PR FAILED") }
        else if cmd.range(of: #"\bvercel\b"#, options: .regularExpression) != nil { kind = ("DEPLOYED", "DEPLOY FAILED") }
        else if cmd.range(of: #"\bgit\s+commit\b"#, options: .regularExpression) != nil { kind = ("COMMIT", "COMMIT FAILED") }
        else { kind = nil }
        guard let k = kind else { return }
        if event == "PostToolUseFailure" {
            // Error text: first line is "Exit code N"; show the first real line after it.
            let lines = (msg["error"] as? String ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            let line = lines.first { !$0.isEmpty && !$0.hasPrefix("Exit code") } ?? lines.first ?? "Command failed"
            IslandModel.shared.celebrate(.redCard(title: k.fail, line: String(line.prefix(140))))
            return
        }
        if k.ok == "COMMIT" {
            var message = ""
            if let r = cmd.range(of: #"-m\s+(["'])(.+?)\1"#, options: .regularExpression) {
                message = String(cmd[r]).replacingOccurrences(of: #"^-m\s+["']"#, with: "", options: .regularExpression)
                message = String(message.dropLast())
            } else if cmd.contains("<<") {
                message = cmd.components(separatedBy: "\n").dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? ""
            }
            GitCelebrations.shared.commit(repo: project, message: String(message.prefix(70)), source: .claude)   // MARK: wip/cinema-h
        } else if k.ok == "PUSHED" {
            GitHubActivity.shared.recentLocalPush[project] = Date()
            GitCelebrations.shared.push(repo: project, detail: "", source: .claude)
        } else {
            IslandModel.shared.celebrate(.deployed(title: k.ok, project: project))
        }
    }

    static func format(duration s: TimeInterval) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(t)s" }
        if t < 3600 { return "\(t / 60)m \(t % 60)s" }
        return "\(t / 3600)h \((t % 3600) / 60)m"
    }

    /// Full, untruncated description of what Claude wants to do.
    static func describe(tool: String, input: [String: Any]) -> (String, String?) {
        switch tool {
        case "Bash":
            return (input["command"] as? String ?? pretty(input), input["description"] as? String)
        case "Write":
            let path = input["file_path"] as? String ?? "?"
            let content = input["content"] as? String ?? ""
            return ("Write \(path)\n\n\(content)", nil)
        case "Edit":
            let path = input["file_path"] as? String ?? "?"
            let old = input["old_string"] as? String ?? ""
            let new = input["new_string"] as? String ?? ""
            let all = (input["replace_all"] as? Bool) == true ? " (replace all)" : ""
            return ("Edit \(path)\(all)\n\n--- old\n\(old)\n\n+++ new\n\(new)", nil)
        case "WebFetch":
            return ("\(input["url"] as? String ?? "")", input["prompt"] as? String)
        default:
            return (pretty(input), nil)
        }
    }

    static func pretty(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return "\(obj)" }
        return s
    }
}

import SwiftUI
