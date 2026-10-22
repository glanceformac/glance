// glance-hook: Claude Code hook helper for Glance.
//
// Reads the hook JSON from stdin and forwards it to Glance over a Unix socket in
// ~/Library/Application Support/Glance/glance.sock (user-only). For PermissionRequest
// it waits up to 58 s for Glance's answer.
//
// Safety rules:
//  * It never allows anything by itself. Only an explicit "allow" from Glance
//    (a button click or ⌃⌥Y) produces an allow decision.
//  * Any failure (Glance not running, bad socket, timeout, malformed reply) exits 0
//    with NO output, so Claude Code shows its normal terminal permission prompt.
//  * Deny returns a proper PermissionRequest deny decision.

import Foundation
import Darwin

let deadlineSeconds: Double = 58

func noDecision() -> Never { exit(0) }

signal(SIGPIPE, SIG_IGN)

let input = FileHandle.standardInput.readDataToEndOfFile()
guard var obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { noDecision() }
let event = obj["hook_event_name"] as? String ?? ""
// MARK: feat/claude-dev
// PreToolUse: only Bash calls matter to Glance (long-command islands). The helper never prints
// anything for PreToolUse, so Claude Code's own permission flow is unchanged.
if event == "PreToolUse", obj["tool_name"] as? String != "Bash" { noDecision() }
// Bash PostToolUse: keep only whether the call was interrupted (no output text).
var responseMeta: [String: Any]? = nil
if event == "PostToolUse", let tr = obj["tool_response"] as? [String: Any], let i = tr["interrupted"] as? Bool {
    responseMeta = ["interrupted": i]
}
// Only PermissionRequest needs the full tool input (shown to you in full). For the other
// events Glance only needs a few small fields, so file contents and tool output are dropped.
if event != "PermissionRequest" {
    if var ti = obj["tool_input"] as? [String: Any] {
        ti = ti.filter { ["command", "file_path", "notebook_path", "description", "run_in_background"].contains($0.key) }
        if let c = ti["command"] as? String { ti["command"] = String(c.prefix(4000)) }
        obj["tool_input"] = ti
    }
    obj.removeValue(forKey: "tool_response")
    if let m = responseMeta { obj["tool_response_meta"] = m } // MARK: feat/claude-dev
    obj.removeValue(forKey: "last_assistant_message")
    if let e = obj["error"] as? String { obj["error"] = String(e.prefix(800)) }
    // Stop / SubagentStop: Glance only counts the background subagents still running (shadow
    // clones), so descriptions, commands and scheduled prompts are dropped.
    if let tasks = obj["background_tasks"] as? [[String: Any]] {
        obj["background_tasks"] = tasks.prefix(50).map { $0.filter { ["type", "status"].contains($0.key) } }
    }
    obj.removeValue(forKey: "session_crons")
    obj.removeValue(forKey: "agent_transcript_path")
}
guard var line = try? JSONSerialization.data(withJSONObject: obj) else { noDecision() }
line.append(0x0A)

// MARK: feat/claude-dev: GLANCE_SOCKET_PATH points the helper at an isolated test instance
// (same ownership checks apply).
let socketPath = ProcessInfo.processInfo.environment["GLANCE_SOCKET_PATH"].flatMap { $0.isEmpty ? nil : $0 }
    ?? (NSHomeDirectory() + "/Library/Application Support/Glance/glance.sock")

// The socket must be a real socket owned by us (not a symlink planted by someone else).
var st = stat()
guard lstat(socketPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { noDecision() }

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { noDecision() }
var one: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
var sendTimeout = timeval(tv_sec: 3, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { noDecision() }
withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    buf.copyBytes(from: pathBytes)
    buf[pathBytes.count] = 0
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { close(fd); noDecision() }

let sentOK: Bool = line.withUnsafeBytes { raw in
    var off = 0
    while off < raw.count {
        let w = write(fd, raw.baseAddress! + off, raw.count - off)
        if w <= 0 { return false }
        off += w
    }
    return true
}
guard sentOK else { close(fd); noDecision() }

guard event == "PermissionRequest" else {
    close(fd)
    exit(0)
}

// Wait for one reply line, with an overall deadline.
let start = Date()
var reply = Data()
var buf = [UInt8](repeating: 0, count: 4096)
while !reply.contains(0x0A) {
    let remaining = deadlineSeconds - Date().timeIntervalSince(start)
    if remaining <= 0 { close(fd); noDecision() }
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let r = poll(&pfd, 1, Int32(remaining * 1000))
    if r < 0 && errno == EINTR { continue }
    if r <= 0 { close(fd); noDecision() }
    let n = read(fd, &buf, buf.count)
    if n <= 0 { close(fd); noDecision() }
    reply.append(contentsOf: buf[0..<n])
    if reply.count > 65536 { close(fd); noDecision() }
}
close(fd)

let replyLine = reply.prefix(while: { $0 != 0x0A })
guard let answer = try? JSONSerialization.jsonObject(with: replyLine) as? [String: Any],
      let decision = answer["decision"] as? String else { noDecision() }

let output: [String: Any]
switch decision {
case "allow":
    output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                     "decision": ["behavior": "allow"]]]
case "deny":
    output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                     "decision": ["behavior": "deny",
                                                  "message": "Denied by the user from Glance."]]]
default:
    noDecision()
}
if let data = try? JSONSerialization.data(withJSONObject: output) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
exit(0)
