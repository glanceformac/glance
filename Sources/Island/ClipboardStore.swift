import AppKit
import SwiftUI
import Observation
import ApplicationServices
import UniformTypeIdentifiers

struct ClipItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, link, image, files }
    var id = UUID()
    var kind: Kind
    var text: String?            // text, or URL string for links
    var paths: [String]?         // file copies: references only, never copied
    var imageFile: String?       // file name inside clipboard-images/
    var title: String?           // custom name (saved snippets)
    var date = Date()
    var sourceApp: String?
    var sourceBundle: String?    // bundle id of the app in front at copy time

    var preview: String {
        switch kind {
        case .text, .link: return (text ?? "").replacingOccurrences(of: "\n", with: " ⏎ ")
        case .image: return "Image"
        case .files:
            let names = (paths ?? []).map { ($0 as NSString).lastPathComponent }
            return names.count <= 1 ? (names.first ?? "File") : "\(names[0]) + \(names.count - 1) more"
        }
    }

    var displayTitle: String { (title?.isEmpty == false ? title! : preview) }

    var symbol: String {
        switch kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .files: "doc"
        }
    }

    /// Identity used to de-duplicate history.
    var contentKey: String {
        switch kind {
        case .text, .link: return "t:" + (text ?? "")
        case .files: return "f:" + (paths ?? []).joined(separator: "|")
        case .image: return "i:" + (imageFile ?? id.uuidString)
        }
    }
}

/// Clipboard history (last 50) + permanent saved snippets.
/// Stored only in ~/Library/Application Support/Glance (0700 dir, 0600 files).
@Observable @MainActor
final class ClipboardStore {
    static let shared = ClipboardStore()
    static let historyLimit = 50

    private(set) var history: [ClipItem] = []
    private(set) var saved: [ClipItem] = []

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCount = Env.pasteboard.changeCount
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    // MARK: feat/productivity
    /// Glance's own copies (Tools: calculator, emoji) are not clipboard history.
    func noteOwnWrite() { lastCount = Env.pasteboard.changeCount }
    @ObservationIgnored private let thumbs = NSCache<NSString, NSImage>()

    private var dir: URL { ClaudeServer.directory }
    private var dataFile: URL { dir.appendingPathComponent("clipboard.json") }
    private var imageDir: URL { dir.appendingPathComponent("clipboard-images", isDirectory: true) }

    private struct Persisted: Codable { var history: [ClipItem]; var saved: [ClipItem] }

    private init() {
        ensureDirs()
        if let d = try? Data(contentsOf: dataFile), let p = try? JSONDecoder().decode(Persisted.self, from: d) {
            history = p.history
            saved = p.saved
        }
    }

    private func ensureDirs() {
        let fm = FileManager.default
        for u in [dir, imageDir] {
            try? fm.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(u.path, 0o700)
        }
    }

    // MARK: Watching

    @ObservationIgnored private var sleepObs: [NSObjectProtocol] = []
    @ObservationIgnored private var screenAsleep = false

    func updateRunning() {
        if sleepObs.isEmpty {
            let ws = NSWorkspace.shared.notificationCenter
            sleepObs.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ClipboardStore.shared.screenAsleep = true; ClipboardStore.shared.updateRunning() }
            })
            sleepObs.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ClipboardStore.shared.screenAsleep = false; ClipboardStore.shared.updateRunning() }
            })
        }
        let paused = AppSettings.shared.prefs.clipboardPaused || screenAsleep
        // Microphone history for dictation apps in the ignore list (event driven, bundle ids only).
        if !paused && !AppSettings.shared.prefs.clipboardIgnoredApps.isEmpty { MicHistory.shared.start() } else { MicHistory.shared.stop() }
        if !paused, timer == nil {
            lastCount = Env.pasteboard.changeCount
            // NSPasteboard has no change notification; comparing one integer every 0.5 s is negligible.
            let t = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { ClipboardStore.shared.check() } }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if paused {
            timer?.invalidate()
            timer = nil
        }
    }

    private func check() {
        let pb = Env.pasteboard
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        let types = pb.types ?? []
        let front = NSWorkspace.shared.frontmostApplication
        // Private markers, ignored apps (password managers) and dictation apps' text: see ClipboardFilter.
        let isText = !types.contains(.fileURL) && types.contains(.string)
        if ClipboardFilter.shouldIgnore(types: types, frontBundle: front?.bundleIdentifier, isText: isText) { return }
        guard var item = capture(pb, source: front?.localizedName) else { return }
        item.sourceBundle = front?.bundleIdentifier
        insert(item)
    }

    private func capture(_ pb: NSPasteboard, source: String?) -> ClipItem? {
        // Files (Finder copies): keep references only.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return ClipItem(kind: .files, paths: urls.map(\.path), sourceApp: source)
        }
        // Images.
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), pb.string(forType: .string) == nil {
            guard let name = storeImage(data) else { return nil }
            return ClipItem(kind: .image, imageFile: name, sourceApp: source)
        }
        // Text / links.
        if let raw = pb.string(forType: .string) {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ClipboardFilter.isFragment(s) else { return nil }   // empty, a space or one character
            let text = String(raw.prefix(200_000))
            if !s.contains(where: \.isWhitespace), let u = URL(string: s), let scheme = u.scheme?.lowercased(),
               ["http", "https", "mailto", "ftp"].contains(scheme) {
                return ClipItem(kind: .link, text: s, sourceApp: source)
            }
            return ClipItem(kind: .text, text: text, sourceApp: source)
        }
        return nil
    }

    private func storeImage(_ data: Data) -> String? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        // Big screenshots are kept at full quality up to 4096 px on the long side.
        var out: Data?
        if max(rep.pixelsWide, rep.pixelsHigh) > 4096, let img = NSImage(data: data) {
            let scale = 4096 / CGFloat(max(rep.pixelsWide, rep.pixelsHigh))
            let size = NSSize(width: CGFloat(rep.pixelsWide) * scale, height: CGFloat(rep.pixelsHigh) * scale)
            let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: r)
            img.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            out = r.representation(using: .png, properties: [:])
        } else {
            out = rep.representation(using: .png, properties: [:])
        }
        guard let png = out else { return nil }
        let name = UUID().uuidString + ".png"
        let url = imageDir.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600]) else { return nil }
        return name
    }

    func debugInsert(_ item: ClipItem) { insert(item) }

    private func insert(_ item: ClipItem) {
        // The same thing again (a re-copy, or a tool putting your old clipboard back): nothing new.
        if let top = history.first, top.kind == item.kind, item.kind != .image, top.contentKey == item.contentKey { return }
        if let i = history.firstIndex(where: { $0.contentKey == item.contentKey && item.kind != .image }) {
            var existing = history.remove(at: i)
            existing.date = Date()
            existing.sourceApp = item.sourceApp
            history.insert(existing, at: 0)
        } else {
            history.insert(item, at: 0)
        }
        while history.count > Self.historyLimit {
            let gone = history.removeLast()
            deleteImageIfUnused(gone)
        }
        scheduleSave()
    }

    // MARK: Actions

    func copy(_ item: ClipItem) {
        let pb = Env.pasteboard
        pb.clearContents()
        switch item.kind {
        case .text: pb.setString(item.text ?? "", forType: .string)
        case .link:
            if let s = item.text, let u = URL(string: s) { pb.writeObjects([u as NSURL]) }
            pb.setString(item.text ?? "", forType: .string)
        case .image:
            if let img = image(for: item) { pb.writeObjects([img]) }
        case .files:
            let urls = (item.paths ?? []).map { URL(fileURLWithPath: $0) as NSURL }
            pb.writeObjects(urls)
        }
        lastCount = pb.changeCount
        // Move to top of history (saved items stay where they are).
        if let i = history.firstIndex(where: { $0.id == item.id }) {
            var h = history.remove(at: i)
            h.date = Date()
            history.insert(h, at: 0)
            scheduleSave()
        }
    }

    /// Copy, close the island, and optionally paste into the front app (needs Accessibility).
    func use(_ item: ClipItem) {
        copy(item)
        Feedback.sound("Tink")
        IslandModel.shared.setExpanded(false)
        let wantsPaste = AppSettings.shared.prefs.pasteAfterCopy && !Env.noPermissions
        if wantsPaste && AXIsProcessTrusted() {
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                Self.postCommandV()
            }
        } else {
            IslandModel.shared.enqueue(Peek(symbol: "doc.on.doc.fill", title: "Copied", subtitle: String(item.displayTitle.prefix(28)), duration: 1.4))
        }
    }

    static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func delete(_ item: ClipItem) {
        history.removeAll { $0.id == item.id }
        saved.removeAll { $0.id == item.id }
        deleteImageIfUnused(item)
        scheduleSave()
    }

    func clearHistory() {
        let old = history
        history.removeAll()
        old.forEach(deleteImageIfUnused)
        scheduleSave()
    }

    func save(_ item: ClipItem) {
        guard !saved.contains(where: { $0.contentKey == item.contentKey }) else { return }
        var s = item
        s.id = UUID()
        s.date = Date()
        if s.kind == .image, let f = item.imageFile {
            // Saved images get their own file so history eviction never removes them.
            let src = imageDir.appendingPathComponent(f)
            let name = UUID().uuidString + ".png"
            try? FileManager.default.copyItem(at: src, to: imageDir.appendingPathComponent(name))
            chmod(imageDir.appendingPathComponent(name).path, 0o600)
            s.imageFile = name
        }
        saved.append(s)
        scheduleSave()
    }

    func addSnippet(title: String, text: String) {
        let t = text.trimmingCharacters(in: .newlines)
        guard !t.isEmpty else { return }
        saved.append(ClipItem(kind: .text, text: t, title: title.isEmpty ? nil : title))
        scheduleSave()
    }

    func rename(_ item: ClipItem, to title: String) {
        guard let i = saved.firstIndex(where: { $0.id == item.id }) else { return }
        saved[i].title = title.trimmingCharacters(in: .whitespaces)
        scheduleSave()
    }

    func moveSaved(_ item: ClipItem, by delta: Int) {
        guard let i = saved.firstIndex(where: { $0.id == item.id }) else { return }
        let j = i + delta
        guard j >= 0, j < saved.count else { return }
        saved.swapAt(i, j)
        scheduleSave()
    }

    // MARK: Images

    func imageURL(for item: ClipItem) -> URL? { item.imageFile.map { imageDir.appendingPathComponent($0) } }

    func image(for item: ClipItem) -> NSImage? { imageURL(for: item).flatMap { NSImage(contentsOf: $0) } }

    func thumbnail(for item: ClipItem) -> NSImage? {
        switch item.kind {
        case .image:
            guard let f = item.imageFile else { return nil }
            if let t = thumbs.object(forKey: f as NSString) { return t }
            guard let img = image(for: item) else { return nil }
            let t = NowPlaying.downscale(img, to: 64)
            thumbs.setObject(t, forKey: f as NSString)
            return t
        case .files:
            guard let p = item.paths?.first else { return nil }
            // Icon by file type only: no disk access, so no privacy prompt or stall for
            // files in Desktop/Documents/Downloads.
            let ext = (p as NSString).pathExtension
            if ext.isEmpty { return NSWorkspace.shared.icon(for: .folder) }
            return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        default: return nil
        }
    }

    private func deleteImageIfUnused(_ item: ClipItem) {
        guard let f = item.imageFile else { return }
        let stillUsed = history.contains { $0.imageFile == f } || saved.contains { $0.imageFile == f }
        if !stillUsed {
            // Only ever deletes Glance's own cached image files.
            try? FileManager.default.removeItem(at: imageDir.appendingPathComponent(f))
            thumbs.removeObject(forKey: f as NSString)
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    func persistNow() {
        guard !Env.isolated else { return } // MARK: feat/system-media (test instances never write the real history)
        ensureDirs()
        guard let d = try? JSONEncoder().encode(Persisted(history: history, saved: saved)) else { return }
        let tmp = dataFile.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600])
        Darwin.rename(tmp.path, dataFile.path) // atomic
        chmod(dataFile.path, 0o600)
    }
}
