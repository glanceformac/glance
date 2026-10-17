// glance-chrome-host: Chrome native messaging host for the Glance for Mac Chrome extension.
// Chrome starts it and talks over stdin/stdout (4-byte little-endian length + JSON).
// It relays each message as one JSON line to Glance over the user-only Unix socket in
// ~/Library/Application Support/Glance. Only colours, band levels, state and the domain
// pass through; anything else in a message is dropped here.
import Foundation
import Darwin

signal(SIGPIPE, SIG_IGN)
let socketPath = ProcessInfo.processInfo.environment["GLANCE_SOCKET_PATH"] ?? (NSHomeDirectory() + "/Library/Application Support/Glance/glance.sock")
let allowedKeys: Set<String> = ["type", "state", "method", "audio", "fullscreen", "domain", "colors", "bands",
                                 "title", "time", "duration", "rate", "live", "cmd", "result", "spectrum", "mediaId", "beats"]
// Only these command names may travel Glance -> Chrome.
let allowedCommands: Set<String> = ["toggle", "back", "forward", "pip", "fullscreen", "fullscreen-window", "titles-on", "titles-off", "play", "focus"]
let outLock = NSLock()
var fd: Int32 = -1
let fdLock = NSLock()   // guards fd (main thread writes, reader thread reads/reconnects)

/// Connects if needed. Called with fdLock held.
private func connectLocked() -> Bool {
    if fd >= 0 { return true }
    var st = stat()
    guard lstat(socketPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { return false }
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    guard s >= 0 else { return false }
    var one: Int32 = 1
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { b in b.copyBytes(from: bytes); b[bytes.count] = 0 }
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard ok == 0 else { close(s); return false }
    fd = s
    _ = writeLocked(["island_stream": "chrome"])
    startReader(s)
    return true
}

private func writeLocked(_ obj: [String: Any]) -> Bool {
    guard fd >= 0, var d = try? JSONSerialization.data(withJSONObject: obj) else { return false }
    d.append(0x0A)
    let ok: Bool = d.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            let w = write(fd, raw.baseAddress! + off, raw.count - off)
            if w <= 0 { return false }
            off += w
        }
        return true
    }
    if !ok { close(fd); fd = -1 }
    return ok
}

func connectIsland() -> Bool { fdLock.lock(); defer { fdLock.unlock() }; return connectLocked() }

/// Sends one message; if the socket turned out dead (Glance restarted), reconnects and resends once.
func sendLine(_ obj: [String: Any]) -> Bool {
    fdLock.lock(); defer { fdLock.unlock() }
    guard connectLocked() else { return false }
    if writeLocked(obj) { return true }
    guard connectLocked() else { return false }
    return writeLocked(obj)
}

/// Reads exactly n bytes from stdin with plain read(2) (FileHandle.readData returned an
/// autoreleased NSData per call, which piled up: the host grew ~6 MB a minute while a video played).
func readExactly(_ n: Int) -> Data? {
    var out = [UInt8](repeating: 0, count: n)
    var got = 0
    while got < n {
        let r = out.withUnsafeMutableBytes { read(0, $0.baseAddress! + got, n - got) }
        if r == 0 { return nil }                       // Chrome closed the port
        if r < 0 { if errno == EINTR { continue }; return nil }
        got += r
    }
    return Data(out)
}

func reply(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
    var len = UInt32(d.count).littleEndian
    outLock.lock(); defer { outLock.unlock() }
    FileHandle.standardOutput.write(Data(bytes: &len, count: 4))
    FileHandle.standardOutput.write(d)
}

/// Glance -> Chrome: player commands from the pill controls.
func startReader(_ s: Int32) {
    Thread.detachNewThread {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(s, &chunk, chunk.count)
            if n <= 0 {
                fdLock.lock()
                if fd == s { close(fd); fd = -1 }
                fdLock.unlock()
                // Glance went away (restart): try again every 2 s so commands work without waiting for a frame.
                while true {
                    sleep(2)
                    fdLock.lock(); let ok = fd >= 0 || connectLocked(); fdLock.unlock()
                    if ok { return }
                }
            }
            buf.append(contentsOf: chunk[0..<n])
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf[buf.startIndex..<nl]
                buf.removeSubrange(buf.startIndex...nl)
                autoreleasepool {
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          obj["type"] as? String == "command", let cmd = obj["cmd"] as? String, allowedCommands.contains(cmd) else { return }
                    reply(["type": "command", "cmd": cmd])
                }
            }
        }
    }
}

// Every message in its own autorelease pool: JSONSerialization and Foundation bridging create
// autoreleased objects, and this loop never returns to a run loop that would drain them.
var running = true
while running {
    autoreleasepool {
        guard let head = readExactly(4) else { running = false; return }
        let len = Int(head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard len > 0, len < 1_000_000, let body = readExactly(len),
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        let clean = obj.filter { allowedKeys.contains($0.key) }
        if (clean["type"] as? String) == "ping" {
            reply(["type": "pong", "island": connectIsland()])
            return
        }
        _ = sendLine(clean)
    }
}
if fd >= 0 { close(fd) }
