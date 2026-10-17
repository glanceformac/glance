import Foundation
import CryptoKit
import Observation

/// Synced lyrics from LRCLIB (https://lrclib.net), cached on disk.
@Observable @MainActor
final class Lyrics {
    static let shared = Lyrics()

    struct Line: Equatable { let time: Double; let text: String }

    private(set) var lines: [Line] = []
    @ObservationIgnored private var currentKey = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    private var cacheDir: URL {
        let u = Env.cachesBase
            .appendingPathComponent("Glance/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func trackChanged() {
        let np = NowPlaying.shared
        guard AppSettings.shared.prefs.lyrics, np.hasMedia, !np.artist.isEmpty else {
            if !lines.isEmpty { lines = [] }
            currentKey = ""
            return
        }
        let key = "\(np.artist)\u{1F}\(np.title)"
        guard key != currentKey else { return }
        currentKey = key
        lines = []
        task?.cancel()
        let artist = np.artist, title = np.title, album = np.album, duration = np.duration
        task = Task { [weak self] in
            // Duration often arrives a moment after the title; wait briefly.
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, self.currentKey == key else { return }
            let d = NowPlaying.shared.duration > 0 ? NowPlaying.shared.duration : duration
            let result = await self.fetch(artist: artist, title: title, album: album, duration: d)
            guard !Task.isCancelled, self.currentKey == key else { return }
            self.lines = result
        }
    }

    /// Index of the line being sung at time `t`.
    func index(at t: Double) -> Int? {
        guard !lines.isEmpty, t >= lines[0].time - 0.3 else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= t + 0.3 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func fetch(artist: String, title: String, album: String, duration: Double) async -> [Line] {
        let hash = SHA256.hash(data: Data("\(artist.lowercased())|\(title.lowercased())".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let file = cacheDir.appendingPathComponent(hash + ".lrc")
        if let cached = try? String(contentsOf: file, encoding: .utf8) {
            return Self.parse(cached)
        }
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [URLQueryItem(name: "artist_name", value: artist), URLQueryItem(name: "track_name", value: title)]
        if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        comps.queryItems = items
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Glance/1.0 (personal macOS app)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return [] }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        var synced = ""
        if status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            synced = obj["syncedLyrics"] as? String ?? ""
        }
        // Cache misses too (empty file) so we don't hammer the API.
        if status == 200 || status == 404 { try? synced.write(to: file, atomically: true, encoding: .utf8) }
        return Self.parse(synced)
    }

    /// Parses `[mm:ss.xx] text` LRC lines.
    static func parse(_ lrc: String) -> [Line] {
        var out: [Line] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var stamps: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) {
                    stamps.append(m * 60 + s)
                }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for t in stamps { out.append(Line(time: t, text: text.isEmpty ? "♪" : text)) }
        }
        return out.sorted { $0.time < $1.time }
    }
}
