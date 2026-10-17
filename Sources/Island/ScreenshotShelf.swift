import AppKit
import SwiftUI
import Vision
import ImageIO
import Observation
import UniformTypeIdentifiers

// MARK: - Screenshot shelf
//
// Watches the folder macOS saves screenshots to (`defaults read com.apple.screencapture location`,
// else ~/Desktop), keeps the newest thumbnails, and reads their text on this Mac with Vision so they
// can be searched. Files are never moved, renamed or deleted. OCR results are cached in
// ~/Library/Application Support/Glance/screenshot-text.json (text only, 0600).

struct ShotItem: Identifiable, Equatable {
    var id: String { url.path }
    var url: URL
    var date: Date
    var name: String { url.lastPathComponent }
}

@Observable @MainActor
final class ScreenshotShelf {
    static let shared = ScreenshotShelf()
    nonisolated static let limit = 30
    nonisolated static let exts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]

    private(set) var items: [ShotItem] = []
    private(set) var thumbs: [String: NSImage] = [:]
    private(set) var text: [String: String] = [:]
    private(set) var folder: URL?
    private(set) var folderReadable = true
    private(set) var indexing = 0

    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var firstScanDone = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var known: Set<String> = []
    @ObservationIgnored private var cache: [String: CachedText] = [:]
    @ObservationIgnored private let ocrQueue = DispatchQueue(label: "island.screenshots.ocr", qos: .utility)
    @ObservationIgnored private var queued: Set<String> = []

    struct CachedText: Codable { var mtime: Double; var text: String }

    private var cacheFile: URL { ClaudeServer.directory.appendingPathComponent("screenshot-text.json") }

    // MARK: Folder

    /// `GLANCE_SCREENSHOT_DIR` is honoured in isolated test instances only.
    static func resolveFolder() -> URL {
        if Env.isolated, let p = ProcessInfo.processInfo.environment["GLANCE_SCREENSHOT_DIR"] { return URL(fileURLWithPath: p, isDirectory: true) }
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !loc.isEmpty {
            return URL(fileURLWithPath: (loc as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    func start() {
        guard !started else { return }
        started = true
        firstScanDone = false
        folder = Self.resolveFolder()
        if !Env.isolated, let d = try? Data(contentsOf: cacheFile), let c = try? JSONDecoder().decode([String: CachedText].self, from: d) {
            cache = c
            for (k, v) in c { text[k] = v.text }
        }
        watch()
        scan()
    }

    func stop() {
        guard started else { return }
        started = false
        source?.cancel(); source = nil
        scanTask?.cancel()
        items = []; thumbs = [:]; text = [:]; known = []; queued = []
    }

    private func watch() {
        guard let folder else { return }
        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else { folderReadable = false; return }
        folderReadable = true
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        s.setEventHandler { MainActor.assumeIsolated { ScreenshotShelf.shared.scheduleScan() } }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }

    private func scheduleScan() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }

    func scan() {
        guard let folder else { return }
        let dedicated = folder.standardizedFileURL.path != FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
            guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                await MainActor.run { ScreenshotShelf.shared.folderReadable = false }
                return
            }
            var found: [ShotItem] = []
            for u in urls where Self.exts.contains(u.pathExtension.lowercased()) {
                let v = try? u.resourceValues(forKeys: Set(keys))
                guard v?.isRegularFile ?? true else { continue }
                // A dedicated screenshot folder takes every image; the Desktop itself only screenshots.
                let n = u.lastPathComponent
                if !dedicated, !(n.hasPrefix("Screenshot") || n.hasPrefix("Screen Shot")) { continue }
                found.append(ShotItem(url: u, date: v?.creationDate ?? v?.contentModificationDate ?? .distantPast))
            }
            found.sort { $0.date > $1.date }
            let top = Array(found.prefix(Self.limit))
            await MainActor.run { ScreenshotShelf.shared.apply(top) }
        }
    }

    private func apply(_ top: [ShotItem]) {
        folderReadable = true
        let newOnes = top.filter { !known.contains($0.id) }
        known = Set(top.map(\.id))
        if top != items { items = top }
        let drop = Set(thumbs.keys).subtracting(known)
        drop.forEach { thumbs[$0] = nil }
        for it in top {
            if thumbs[it.id] == nil { loadThumb(it) }
            indexIfNeeded(it)
        }
        if firstScanDone {
            for n in newOnes where -n.date.timeIntervalSinceNow < 20 { announce(n) }
        }
        firstScanDone = true
    }

    // MARK: Thumbnails

    private func loadThumb(_ it: ShotItem) {
        let url = it.url, id = it.id
        Task.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 360,
                                         kCGImageSourceCreateThumbnailWithTransform: true]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
            await MainActor.run { ScreenshotShelf.shared.thumbs[id] = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2)) }
        }
    }

    // MARK: OCR (Vision, on this Mac)

    private func indexIfNeeded(_ it: ShotItem) {
        guard AppSettings.shared.prefs.screenshotOCR else { return }
        let mtime = (try? it.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        if let c = cache[it.id], c.mtime == mtime { return }
        guard queued.insert(it.id).inserted else { return }
        indexing += 1
        let url = it.url, id = it.id
        ocrQueue.async {
            let result = Self.recognise(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let s = ScreenshotShelf.shared
                    s.queued.remove(id)
                    s.indexing = max(0, s.indexing - 1)
                    guard let result else { return }
                    s.text[id] = result
                    s.cache[id] = CachedText(mtime: mtime, text: result)
                    s.saveCache()
                }
            }
        }
    }

    /// Reads text from an image file. Downscales big captures first to keep CPU and memory low.
    nonisolated static func recognise(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2000,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return String(lines.joined(separator: "\n").prefix(6000))
    }

    private func saveCache() {
        guard !Env.isolated else { return }
        // Keep only entries for screenshots still on the shelf.
        cache = cache.filter { known.contains($0.key) }
        guard let d = try? JSONEncoder().encode(cache) else { return }
        let tmp = cacheFile.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600])
        Darwin.rename(tmp.path, cacheFile.path)
    }

    // MARK: Peek

    private func announce(_ it: ShotItem) {
        guard AppSettings.shared.prefs.screenshotPeek else { return }
        let url = it.url
        var p = Peek(symbol: "camera.viewfinder", title: "Screenshot saved", subtitle: nil, tint: .white, duration: 3.2)
        if let t = thumbs[it.id] { p.icon = t }
        p.actionTitle = "Copy"
        p.action = { ScreenshotShelf.copyImage(url) }
        IslandModel.shared.enqueue(p)
        Feedback.haptic(.levelChange)
        // The thumbnail may not be ready yet; it appears in the shelf either way.
    }

    // MARK: Search

    func matches(_ it: ShotItem, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return it.name.lowercased().contains(q) || (text[it.id]?.lowercased().contains(q) ?? false)
    }

    /// A short line of recognised text around the first match, for display while searching.
    func snippet(_ it: ShotItem, query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, let t = text[it.id] else { return nil }
        for line in t.split(separator: "\n") where line.lowercased().contains(q) { return String(line.prefix(60)) }
        return nil
    }

    // MARK: Actions (never modify the files)

    static func copyImage(_ url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        let pb = Env.pasteboard
        pb.clearContents()
        pb.writeObjects([img])
    }

    func quickLook(_ it: ShotItem) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", it.url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func reveal(_ it: ShotItem) { NSWorkspace.shared.activateFileViewerSelecting([it.url]) }
    func open(_ it: ShotItem) { NSWorkspace.shared.open(it.url); IslandModel.shared.setExpanded(false) }
    func openFolder() { if let folder { NSWorkspace.shared.open(folder); IslandModel.shared.setExpanded(false) } }
}

// MARK: - UI

struct ScreenshotsView: View {
    let theme: Theme
    private let shots = ScreenshotShelf.shared
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let list = shots.items.filter { shots.matches($0, query: query) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.secondary)
                    TextField("Search screenshots and the text in them", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(theme.primary).focused($focused)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.tertiary) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(focused ? theme.accent.opacity(0.8) : .clear, lineWidth: 1.2))
                if shots.indexing > 0 {
                    Text("Reading text \(shots.indexing)").font(.system(size: 10)).foregroundStyle(theme.tertiary)
                }
                Button { shots.openFolder() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 10, weight: .semibold))
                        Text("Folder").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(theme.primary).padding(.horizontal, 10).frame(height: 26).background(Capsule().fill(theme.card))
                }
                .buttonStyle(PressScaleStyle())
                .help(shots.folder?.path ?? "")
            }
            if !shots.folderReadable {
                emptyNote("Glance can't read \(shots.folder?.lastPathComponent ?? "the screenshot folder"). Allow it in System Settings, Privacy & Security, Files and Folders.")
            } else if list.isEmpty {
                emptyNote(query.isEmpty ? "Screenshots you take appear here. Drag them out, press space for Quick Look, search the words inside them." : "No screenshot matches \"\(query)\".")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(list) { ShotTile(item: $0, theme: theme, query: query) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func emptyNote(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(theme.tertiary).padding(.horizontal, 8).padding(.top, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ShotTile: View {
    let item: ShotItem
    let theme: Theme
    let query: String
    @State private var hover = false
    private let shots = ScreenshotShelf.shared

    var body: some View {
        let hit = shots.snippet(item, query: query)
        VStack(spacing: 5) {
            Group {
                if let t = shots.thumbs[item.id] {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").font(.system(size: 20, weight: .light)).foregroundStyle(theme.secondary)
                }
            }
            .frame(width: 132, height: 84)
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if shots.text[item.id]?.isEmpty == false {
                    Image(systemName: "text.viewfinder").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(3).background(Circle().fill(Color.black.opacity(0.55))).padding(4)
                        .help("Text found in this screenshot")
                }
            }
            Text(hit ?? item.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 9.5, weight: hit == nil ? .regular : .semibold)).foregroundStyle(hit == nil ? theme.secondary : theme.accent)
                .lineLimit(1).frame(width: 132)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.card.opacity(hover ? 1.4 : 0.6)))
        .scaleEffect(hover ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
        .onHover { hover = $0 }
        .onTapGesture { shots.quickLook(item) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Quick Look") { shots.quickLook(item) }
            Button("Open") { shots.open(item) }
            Button("Show in Finder") { shots.reveal(item) }
            Divider()
            Button("Copy Image") { ScreenshotShelf.copyImage(item.url) }
            if let t = shots.text[item.id], !t.isEmpty {
                Button("Copy Text from Image") {
                    Env.pasteboard.clearContents()
                    Env.pasteboard.setString(t, forType: .string)
                }
            }
            Button("Add to Shelf") { ShelfStore.shared.addFile(item.url) }
            if AirDrop.available { Button("AirDrop…") { AirDrop.send(urls: [item.url]) } }
        }
        .help(item.name)
        .accessibilityLabel("Screenshot \(item.name)")
    }
}
