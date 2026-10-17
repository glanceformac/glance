import AppKit
import SwiftUI
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct ShelfItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case file, image, text, link }
    var id = UUID()
    var kind: Kind
    var name: String
    var bookmark: Data?        // files: a reference (bookmark), not a copy
    var lastPath: String?      // last resolved path, for display
    var text: String?          // text or link
    var imageFile: String?     // dropped image data (no file behind it) saved in shelf-images/
    var date = Date()

    init(kind: Kind, name: String, bookmark: Data? = nil, lastPath: String? = nil, text: String? = nil, imageFile: String? = nil) {
        self.kind = kind; self.name = name; self.bookmark = bookmark; self.lastPath = lastPath
        self.text = text; self.imageFile = imageFile
    }

    /// Tolerant decoding: a missing field never wipes the Shelf.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        lastPath = try? c.decodeIfPresent(String.self, forKey: .lastPath)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .file
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? (lastPath.map { ($0 as NSString).lastPathComponent } ?? "Item")
        bookmark = try? c.decodeIfPresent(Data.self, forKey: .bookmark)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        imageFile = try? c.decodeIfPresent(String.self, forKey: .imageFile)
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date()
    }
}

/// Decodes each element on its own so one bad entry can't empty the list.
struct LenientList<T: Decodable>: Decodable {
    var items: [T] = []
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) { items.append(v) } else { _ = try? c.decode(Skip.self) }
        }
    }
    private struct Skip: Decodable {}
}

/// The Shelf: things dragged onto the island, kept until removed. Persisted in
/// ~/Library/Application Support/Glance/shelf.json (0600).
@Observable @MainActor
final class ShelfStore {
    static let shared = ShelfStore()
    private(set) var items: [ShelfItem] = []
    var thumbnails: [UUID: NSImage] = [:]
    /// File locations resolved off the main thread (bookmark resolution can block on
    /// disk or on a macOS privacy check, so it never runs during rendering).
    private(set) var resolved: [UUID: URL] = [:]
    private(set) var missing: Set<UUID> = []

    private var dir: URL { ClaudeServer.directory }
    private var dataFile: URL { dir.appendingPathComponent("shelf.json") }
    private var imageDir: URL { dir.appendingPathComponent("shelf-images", isDirectory: true) }

    private init() {
        for u in [dir, imageDir] {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(u.path, 0o700)
        }
        if let d = try? Data(contentsOf: dataFile) {
            if let list = try? JSONDecoder().decode(LenientList<ShelfItem>.self, from: d) {
                defer { savedCount = items.count }
                items = list.items.filter { $0.lastPath != nil || $0.text != nil || $0.imageFile != nil }
            } else {
                // Unreadable file: keep a copy instead of overwriting it with an empty Shelf.
                try? d.write(to: dataFile.appendingPathExtension("unreadable"))
            }
        }
        refreshResolution()
    }

    /// Resolve all file bookmarks in the background; refresh stale ones.
    func refreshResolution() {
        let files = items.filter { $0.kind == .file }
        guard !files.isEmpty else { return }
        Task.detached(priority: .utility) {
            var found: [UUID: (URL, Data?)] = [:]
            var lost: Set<UUID> = []
            for it in files {
                var url: URL?
                var newBM: Data?
                if let bm = it.bookmark {
                    var stale = false
                    if let u = try? URL(resolvingBookmarkData: bm, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                        url = u
                        if stale { newBM = try? u.bookmarkData() }
                    }
                }
                if url == nil, let p = it.lastPath, FileManager.default.fileExists(atPath: p) { url = URL(fileURLWithPath: p) }
                if let u = url, FileManager.default.fileExists(atPath: u.path) { found[it.id] = (u, newBM) } else { lost.insert(it.id) }
            }
            let result = found, gone = lost
            await MainActor.run { ShelfStore.shared.applyResolution(result, missing: gone) }
        }
    }

    private func applyResolution(_ found: [UUID: (URL, Data?)], missing gone: Set<UUID>) {
        var changed = false
        for (id, (u, bm)) in found {
            resolved[id] = u
            if let i = items.firstIndex(where: { $0.id == id }) {
                if items[i].lastPath != u.path { items[i].lastPath = u.path; items[i].name = u.lastPathComponent; changed = true }
                if let bm { items[i].bookmark = bm; changed = true }
            }
        }
        missing = gone
        if changed { save() }
        for it in items where it.kind == .file && thumbnails[it.id] == nil { loadThumbnail(it) }
    }

    // MARK: Adding

    func add(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in ShelfStore.shared.addFile(url) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                accepted = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in ShelfStore.shared.addLink(url) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in ShelfStore.shared.addImageData(data) }
                }
            } else if p.canLoadObject(ofClass: NSString.self) {
                accepted = true
                _ = p.loadObject(ofClass: NSString.self) { s, _ in
                    guard let s = s as? String else { return }
                    Task { @MainActor in ShelfStore.shared.addText(s) }
                }
            }
        }
        return accepted
    }

    func addFile(_ url: URL) {
        guard url.isFileURL else { addLink(url); return }
        guard !items.contains(where: { $0.lastPath == url.path }) else { return }
        // Bookmark (a reference, not a copy) is created off the main thread.
        Task.detached(priority: .userInitiated) {
            let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            await MainActor.run {
                let item = ShelfItem(kind: .file, name: url.lastPathComponent, bookmark: bm, lastPath: url.path)
                ShelfStore.shared.resolved[item.id] = url
                ShelfStore.shared.insert(item)
            }
        }
    }

    func addLink(_ url: URL) {
        let host = url.host ?? url.absoluteString
        insert(ShelfItem(kind: .link, name: host, text: url.absoluteString))
    }

    func addText(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !t.contains(where: \.isWhitespace), let u = URL(string: t), let sc = u.scheme, ["http", "https"].contains(sc) {
            addLink(u); return
        }
        insert(ShelfItem(kind: .text, name: String(t.prefix(40)), text: String(t.prefix(200_000))))
    }

    func addImageData(_ data: Data) {
        guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return }
        let name = UUID().uuidString + ".png"
        let url = imageDir.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600]) else { return }
        insert(ShelfItem(kind: .image, name: "Image", imageFile: name))
    }

    fileprivate func insert(_ item: ShelfItem) {
        withAnimation(IslandModel.openSpring) { items.insert(item, at: 0) }
        save()
        loadThumbnail(item)
    }

    // MARK: Using

    /// Location of an item. Files use the background-resolved bookmark.
    func url(for item: ShelfItem) -> URL? {
        switch item.kind {
        case .file: return resolved[item.id] ?? item.lastPath.map { URL(fileURLWithPath: $0) }
        case .image: return item.imageFile.map { imageDir.appendingPathComponent($0) }
        case .link: return item.text.flatMap(URL.init(string:))
        case .text: return nil
        }
    }

    func isMissing(_ item: ShelfItem) -> Bool { missing.contains(item.id) }

    func open(_ item: ShelfItem) {
        if item.kind == .text {
            let pb = Env.pasteboard
            pb.clearContents()
            pb.setString(item.text ?? "", forType: .string)
            IslandModel.shared.enqueue(Peek(symbol: "doc.on.doc.fill", title: "Copied", duration: 1.2))
        } else if let u = url(for: item) {
            NSWorkspace.shared.open(u)
        }
        IslandModel.shared.setExpanded(false)
    }

    func quickLook(_ item: ShelfItem) {
        guard let u = url(for: item), u.isFileURL else { open(item); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", u.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func reveal(_ item: ShelfItem) {
        guard let u = url(for: item), u.isFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    func dragProvider(for item: ShelfItem) -> NSItemProvider {
        switch item.kind {
        case .file, .image:
            if let u = url(for: item), let p = NSItemProvider(contentsOf: u) { return p }
        case .link:
            if let u = url(for: item) { return NSItemProvider(object: u as NSURL) }
        case .text: break
        }
        return NSItemProvider(object: (item.text ?? item.name) as NSString)
    }

    func remove(_ item: ShelfItem) {
        withAnimation(IslandModel.openSpring) { items.removeAll { $0.id == item.id } }
        thumbnails[item.id] = nil
        // Only Glance's own stored image data is deleted; referenced files are never touched.
        if let f = item.imageFile { try? FileManager.default.removeItem(at: imageDir.appendingPathComponent(f)) }
        save()
    }

    /// Clear All: the backup is taken once, with every item in it, before anything is removed.
    func clear() {
        guard !items.isEmpty else { return }
        backUp()
        backupDone = true
        items.forEach(remove)
        backupDone = false
    }

    // MARK: Thumbnails

    func loadThumbnail(_ item: ShelfItem) {
        guard thumbnails[item.id] == nil else { return }
        switch item.kind {
        case .text, .link: return
        case .image:
            if let u = url(for: item), let img = NSImage(contentsOf: u) { thumbnails[item.id] = NowPlaying.downscale(img, to: 112) }
        case .file:
            guard let u = resolved[item.id] else { return }
            let id0 = item.id
            Task.detached(priority: .utility) {
                // NSImage is not Sendable; this one is created here and only handed to the main actor.
                let icon = UncheckedImage(image: NSWorkspace.shared.icon(forFile: u.path))
                await MainActor.run { if ShelfStore.shared.thumbnails[id0] == nil { ShelfStore.shared.thumbnails[id0] = icon.image } }
            }
            let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: 56, height: 56), scale: 2, representationTypes: .thumbnail)
            let id = item.id
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                guard let img = rep?.nsImage else { return }
                Task { @MainActor in ShelfStore.shared.thumbnails[id] = img }
            }
        }
    }

    @ObservationIgnored private var savedCount = -1
    /// Set while Clear All runs, so the per-item saves do not overwrite the full backup.
    @ObservationIgnored private var backupDone = false

    /// Keeps the current file as shelf.json.bak (one-step undo).
    private func backUp() {
        let bak = dataFile.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.copyItem(at: dataFile, to: bak)
    }

    private func save(_ reason: String = #function) {
        guard let d = try? JSONEncoder().encode(items) else { return }
        // Before items disappear, keep the previous file as shelf.json.bak (one-step undo).
        if !backupDone && (savedCount > items.count || (savedCount < 0 && items.isEmpty)) { backUp() }
        ChromeAmbilight.log.info("shelf saved \(self.items.count) items (\(reason, privacy: .public))")
        savedCount = items.count
        let tmp = dataFile.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600])
        Darwin.rename(tmp.path, dataFile.path)
    }
}

/// Carries an image created off the main thread to the main actor exactly once.
private struct UncheckedImage: @unchecked Sendable { let image: NSImage }
