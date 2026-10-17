import AppKit
import Observation

/// System-wide now playing via the open-source mediaremote-adapter
/// (https://github.com/ungive/mediaremote-adapter, BSD-3-Clause), which runs the
/// MediaRemote calls inside /usr/bin/perl (an entitled system binary).
/// Fallback: Spotify / Music distributed notifications + AppleScript controls.
@Observable @MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    var title = ""
    var artist = ""
    var album = ""
    var artwork: NSImage?
    var isPlaying = false
    var duration: Double = 0
    var bundleID = ""
    @ObservationIgnored var elapsedAtStamp: Double = 0
    @ObservationIgnored var stamp = Date()
    @ObservationIgnored var rate: Double = 1

    var hasMedia: Bool { !title.isEmpty }

    var elapsed: Double {
        guard isPlaying else { return elapsedAtStamp }
        let e = elapsedAtStamp + Date().timeIntervalSince(stamp) * max(rate, 0.01)
        return duration > 0 ? min(e, duration) : e
    }

    var appIcon: NSImage? {
        guard !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var streamLifeline: Pipe?
    @ObservationIgnored private var state: [String: Any] = [:]
    @ObservationIgnored private var lineBuffer = Data()
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var usingFallback = false
    @ObservationIgnored private var lastArtworkHash = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private var resources: URL? { Bundle.main.resourceURL?.appendingPathComponent("mediaremote") }
    private var scriptPath: String? { resources?.appendingPathComponent("mediaremote-adapter.pl").path }
    private var frameworkPath: String? { resources?.appendingPathComponent("MediaRemoteAdapter.framework").path }

    func start() {
        guard AppSettings.shared.prefs.nowPlaying else { return }
        if let s = scriptPath, let f = frameworkPath,
           FileManager.default.fileExists(atPath: s), FileManager.default.fileExists(atPath: f) {
            launchStream(script: s, framework: f)
        } else {
            startFallback()
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        clear()
    }

    private func launchStream(script: String, framework: String) {
        let p = Process()
        // Run the adapter under a tiny sh supervisor: if Glance exits or crashes, our end of
        // the stdin pipe closes and the supervisor kills perl, so nothing is left running.
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c",
                       // fd 3 keeps the lifeline: POSIX sh gives background jobs /dev/null as stdin.
                       "exec 3<&0; /usr/bin/perl \"$@\" </dev/null & p=$!; (read _ <&3; kill $p 2>/dev/null) & trap 'kill $p 2>/dev/null; exit 0' TERM; wait $p",
                       "island-mediaremote", script, framework, "stream", "--micros", "--debounce=80"]
        let out = Pipe()
        let lifeline = Pipe()
        p.standardInput = lifeline
        streamLifeline = lifeline
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            Task { @MainActor in self?.ingest(data) }
        }
        let started = Date()
        p.terminationHandler = { [weak self] proc in
            let quick = Date().timeIntervalSince(started) < 3
            let code = proc.terminationStatus
            Task { @MainActor in self?.streamEnded(quick: quick, code: code) }
        }
        do {
            try p.run()
            process = p
        } catch {
            startFallback()
        }
    }

    private func streamEnded(quick: Bool, code: Int32) {
        process = nil
        guard AppSettings.shared.prefs.nowPlaying else { return }
        if quick { restarts += 1 }
        if restarts >= 3 {
            NSLog("Glance: mediaremote-adapter failing (exit \(code)); using Spotify/Music fallback")
            startFallback()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.start()
        }
    }

    private func ingest(_ data: Data) {
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<nl]
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }
            let diff = obj["diff"] as? Bool ?? false
            if diff {
                for (k, v) in payload {
                    if v is NSNull { state.removeValue(forKey: k) } else { state[k] = v }
                }
            } else {
                state = payload
            }
            apply(state)
        }
        if lineBuffer.count > 16_000_000 { lineBuffer.removeAll() }
    }

    private func apply(_ s: [String: Any]) {
        let newTitle = s["title"] as? String ?? ""
        let newArtist = s["artist"] as? String ?? ""
        if newTitle != title { title = newTitle }
        if newArtist != artist { artist = newArtist }
        // Assign only on change: every observable write invalidates SwiftUI views.
        let newAlbum = s["album"] as? String ?? ""
        if newAlbum != album { album = newAlbum }
        let newBundle = (s["parentApplicationBundleIdentifier"] as? String) ?? (s["bundleIdentifier"] as? String) ?? ""
        if newBundle != bundleID { bundleID = newBundle }
        let playing = s["playing"] as? Bool ?? false
        let newDuration = ((s["durationMicros"] as? Double) ?? 0) / 1_000_000
        if abs(newDuration - duration) > 0.5 { duration = newDuration }
        elapsedAtStamp = ((s["elapsedTimeMicros"] as? Double) ?? 0) / 1_000_000
        if let ts = s["timestampEpochMicros"] as? Double {
            stamp = Date(timeIntervalSince1970: ts / 1_000_000)
        } else {
            stamp = Date()
        }
        rate = s["playbackRate"] as? Double ?? 1
        if playing != isPlaying { isPlaying = playing }

        if let b64 = s["artworkData"] as? String {
            let h = b64.hashValue
            if h != lastArtworkHash, let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                lastArtworkHash = h
                artwork = NSImage(data: d).map { Self.downscale($0, to: 160) }
            }
        } else if s["artworkData"] == nil && lastArtworkHash != 0 && newTitle.isEmpty {
            artwork = nil
            lastArtworkHash = 0
        }
        if newTitle != lastLyricsKey { lastLyricsKey = newTitle; Lyrics.shared.trackChanged() }
    }
    @ObservationIgnored private var lastLyricsKey = ""

    private func clear() {
        title = ""; artist = ""; album = ""; artwork = nil; isPlaying = false; duration = 0
        lastArtworkHash = 0
        Lyrics.shared.trackChanged()
    }

    /// Keep artwork small in memory (8 GB machine).
    static func downscale(_ img: NSImage, to side: CGFloat) -> NSImage {
        let target = NSSize(width: side, height: side)
        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    // MARK: Controls

    enum Command: Int { case togglePlayPause = 2, next = 4, previous = 5 }

    func send(_ c: Command) {
        if usingFallback { fallbackSend(c); return }
        guard let s = scriptPath, let f = frameworkPath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [s, f, "send", String(c.rawValue)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        if c == .togglePlayPause {
            // Optimistic UI; the stream confirms shortly after.
            elapsedAtStamp = elapsed; stamp = Date(); isPlaying.toggle()
        }
    }

    // MARK: Fallback (Spotify / Music only)

    private func startFallback() {
        guard !usingFallback else { return }
        usingFallback = true
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            observers.append(dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] n in
                let info = n.userInfo ?? [:]
                let bundle = name.hasPrefix("com.spotify") ? "com.spotify.client" : "com.apple.Music"
                MainActor.assumeIsolated { self?.applyFallback(info, bundle: bundle) }
            })
        }
    }

    private func applyFallback(_ info: [AnyHashable: Any], bundle: String) {
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" { clear(); return }
        title = info["Name"] as? String ?? ""
        artist = info["Artist"] as? String ?? ""
        album = info["Album"] as? String ?? ""
        bundleID = bundle
        isPlaying = state == "Playing"
        let total = (info["Duration"] as? Double) ?? (info["Total Time"] as? Double).map { $0 / 1000 } ?? 0
        duration = total > 10_000 ? total / 1000 : total
        elapsedAtStamp = info["Playback Position"] as? Double ?? 0
        stamp = Date()
        artwork = nil
        Lyrics.shared.trackChanged()
    }

    private func fallbackSend(_ c: Command) {
        let app = bundleID == "com.spotify.client" ? "Spotify" : "Music"
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return }
        let verb: String
        switch c {
        case .togglePlayPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        AppleScriptRunner.run("tell application \"\(app)\" to \(verb)")
    }
}

enum AppleScriptRunner {
    private static let queue = DispatchQueue(label: "island.applescript")
    static func run(_ source: String, completion: (@Sendable (Bool) -> Void)? = nil) {
        if Env.noPermissions {
            NSLog("Glance (no-permissions mode): skipped AppleScript: \(source)")
            completion?(false)
            return
        }
        queue.async {
            var err: NSDictionary?
            let ok = NSAppleScript(source: source)?.executeAndReturnError(&err) != nil
            if !ok { NSLog("Glance AppleScript error: \(String(describing: err))") }
            completion?(ok && err == nil)
        }
    }
}
