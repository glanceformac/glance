import AppKit
import SwiftUI
import Observation

// MARK: feat/productivity - App launcher: favourites grid + search across every installed app

struct AppEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let bundleID: String
    var id: String { bundleID.isEmpty ? url.path : bundleID }
}

@Observable @MainActor
final class AppIndex {
    static let shared = AppIndex()
    private(set) var apps: [AppEntry] = []
    private(set) var loaded = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private let iconCache = NSCache<NSString, NSImage>()

    func loadIfNeeded() {
        guard !loaded, !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let found = Self.scan()
            await MainActor.run {
                self.apps = found
                self.loaded = true
                self.loading = false
                // First run: seed favourites with the usual suspects that are installed.
                if ToolsPrefs.shared.data.favouriteApps.isEmpty {
                    let defaults = ["com.apple.Safari", "com.apple.mail", "com.apple.Notes", "com.apple.iCal", "com.apple.Terminal", "com.apple.finder",
                                    "com.apple.MobileSMS", "com.apple.Music", "com.apple.systempreferences"]
                    ToolsPrefs.shared.data.favouriteApps = defaults.filter { id in found.contains { $0.bundleID == id } }
                }
            }
        }
    }

    nonisolated private static func scan() -> [AppEntry] {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                     NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Applications"]
        var out: [String: AppEntry] = [:]
        func visit(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for n in names where !n.hasPrefix(".") {
                let path = dir + "/" + n
                if n.hasSuffix(".app") {
                    let url = URL(fileURLWithPath: path)
                    let bundle = Bundle(url: url)
                    let bid = bundle?.bundleIdentifier ?? ""
                    let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                    let e = AppEntry(url: url, name: name, bundleID: bid)
                    out[e.id] = out[e.id] ?? e
                } else if depth < 2 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { visit(path, depth: depth + 1) }
                }
            }
        }
        for r in roots { visit(r, depth: 0) }
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        out["com.apple.finder"] = AppEntry(url: finder, name: "Finder", bundleID: "com.apple.finder")
        return out.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func icon(_ e: AppEntry) -> NSImage {
        if let i = iconCache.object(forKey: e.url.path as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: e.url.path)
        i.size = NSSize(width: 40, height: 40)
        iconCache.setObject(i, forKey: e.url.path as NSString)
        return i
    }

    func search(_ q: String) -> [AppEntry] {
        let s = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return [] }
        let starts = apps.filter { $0.name.lowercased().hasPrefix(s) }
        let contains = apps.filter { !$0.name.lowercased().hasPrefix(s) && $0.name.lowercased().contains(s) }
        return starts + contains
    }
}

struct AppLauncherView: View {
    let theme: Theme
    private let index = AppIndex.shared
    private let prefs = ToolsPrefs.shared
    @Bindable private var vs = ToolsViewState.shared
    private var query: String { vs.appQuery }
    @FocusState private var focused: Bool
    private let cols = Array(repeating: GridItem(.flexible(minimum: 70), spacing: 6), count: 7)

    var body: some View {
        let results = index.search(query)
        let favs = prefs.data.favouriteApps.compactMap { id in index.apps.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 8) {
            ToolField(theme: theme, placeholder: "Search all apps, press Return to open the first", text: $vs.appQuery, focus: $focused) {
                if let first = results.first { open(first) }
            }
            ScrollView {
                if !index.loaded {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(20)
                } else if query.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Favourites").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.tertiary)
                        if favs.isEmpty {
                            Text("Search for an app, then right-click it to add it here.").font(.system(size: 11)).foregroundStyle(theme.tertiary)
                        }
                        LazyVGrid(columns: cols, spacing: 6) { ForEach(favs) { tile($0) } }
                    }
                } else if results.isEmpty {
                    Text("No app matches \"\(query)\"").font(.system(size: 11)).foregroundStyle(theme.tertiary).padding(14)
                } else {
                    LazyVGrid(columns: cols, spacing: 6) { ForEach(results.prefix(35)) { tile($0) } }
                }
            }
            Text("\(index.apps.count) apps · right-click to add or remove a favourite").font(.system(size: 9)).foregroundStyle(theme.tertiary)
        }
        .onAppear { focused = true; index.loadIfNeeded() }
    }

    private func tile(_ e: AppEntry) -> some View {
        let isFav = prefs.data.favouriteApps.contains(e.id)
        return Button { open(e) } label: {
            VStack(spacing: 3) {
                Image(nsImage: index.icon(e)).resizable().frame(width: 38, height: 38)
                Text(e.name).font(.system(size: 10)).foregroundStyle(theme.primary).lineLimit(1).minimumScaleFactor(0.8).padding(.horizontal, 3)
            }
            .frame(maxWidth: .infinity).frame(height: 66)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card))
            .overlay(alignment: .topTrailing) {
                if isFav && !query.isEmpty { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow).padding(5) }
            }
        }
        .buttonStyle(PressScaleStyle())
        .contextMenu {
            if isFav { Button("Remove from favourites") { prefs.data.favouriteApps.removeAll { $0 == e.id } } }
            else { Button("Add to favourites") { prefs.data.favouriteApps.append(e.id) } }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }
        }
        .help(e.name)
    }

    private func open(_ e: AppEntry) {
        NSWorkspace.shared.openApplication(at: e.url, configuration: NSWorkspace.OpenConfiguration())
        IslandModel.shared.setExpanded(false)
    }
}
