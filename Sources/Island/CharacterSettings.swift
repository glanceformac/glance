import AppKit
import SwiftUI
import WebKit

// MARK: wip/character: Settings › Character

struct CharacterSettingsSections: View {
    @Bindable private var settings = AppSettings.shared
    private let library = CharacterLibrary.shared
    private let engine = CharacterEngine.shared

    var body: some View {
        let c = settings.prefs.character
        let pack = library.pack(c.packID)
        Section("Character") {
            Toggle("Character on", isOn: $settings.prefs.character.enabled)
            VStack(spacing: 6) {
                packRow(nil, selected: !c.enabled)
                ForEach(library.packs) { p in packRow(p, selected: c.enabled && c.packID == p.id) }
            }
            if let pack, !pack.credit.isEmpty {
                Text(pack.credit).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Reduce motion (stills only)", isOn: $settings.prefs.character.reduceMotion)
            Text("Also follows macOS Reduce Motion, and shows stills in Low Power Mode. Videos and animations pause whenever the island is hidden or the screen sleeps.")
                .font(.caption).foregroundStyle(.secondary)
            if TouchBarAPI.available {
                Toggle("Show in Touch Bar", isOn: $settings.prefs.character.touchBar)
            }
            Toggle("Shadow clones for Claude Code agents", isOn: $settings.prefs.character.clones)
            HStack {
                Button("Open Characters Folder") { library.openFolder() }
                Button("Reload Packs") { library.reload(); engine.tick(force: true) }
                Spacer()
                Button("Touch Bar Preview") { CharacterTouchBar.shared.showPreview() }
            }
            Text("A pack is a folder with a manifest.json and its art, in \(CharacterLibrary.folder.path). Packs stay on this Mac.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        Section("Try it on your notch") {
            LiveStateButtons()
        }
        Section("Preview") {
            if let pack, let folder = pack.folder, PackPreviewPages.pages(folder).isEmpty == false {
                PackPreviewPages(folder: folder)
            } else {
                NativeCharacterPreview(pack: pack ?? MochiArt.pack)
            }
        }
    }

    private func packRow(_ p: CharacterPack?, selected: Bool) -> some View {
        Button {
            var prefs = settings.prefs
            if let p { prefs.character.packID = p.id; prefs.character.enabled = true } else { prefs.character.enabled = false }
            settings.prefs = prefs
            engine.tick(force: true)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black)
                    if let p, let a = p.avatar {
                        Image(decorative: a, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(4)
                    } else {
                        Image(systemName: "nosign").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p?.name ?? "None").font(.system(size: 13, weight: .semibold))
                    Text(p?.summary.isEmpty == false ? p!.summary : (p == nil ? "No character. Glance works exactly as before." : "Personal pack"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(selected ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Plays a state on the real island for 12 s (any pack), so you can see it in your own notch.
private struct LiveStateButtons: View {
    private let engine = CharacterEngine.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(CharacterState.allCases) { s in
                    Button(s.title) { engine.preview(s) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            HStack {
                Text(engine.override.map { "Showing \($0.title) on the notch for a few seconds" } ?? "Real state: \(engine.frame.state.title)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if engine.override != nil { Button("Back to live") { engine.preview(nil) } }
            }
        }
        .disabled(!engine.active)
    }
}

// MARK: - The pack's own HTML previews (local files only)

struct PackPreviewPages: View {
    let folder: URL
    @State private var tab = 0

    static func pages(_ folder: URL) -> [(String, URL)] {
        let dir = folder.appendingPathComponent("preview", isDirectory: true)
        return [("Notch", "index.html"), ("Touch Bar", "touchbar.html"), ("Shadow Clones", "clones.html")].compactMap { name, file in
            let u = dir.appendingPathComponent(file)
            return FileManager.default.fileExists(atPath: u.path) ? (name, u) : nil
        }
    }

    var body: some View {
        let list = Self.pages(folder)
        VStack(spacing: 8) {
            if list.count > 1 {
                Picker("", selection: $tab) {
                    ForEach(Array(list.enumerated()), id: \.offset) { i, p in Text(p.0).tag(i) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if !list.isEmpty {
                let page = list[min(tab, list.count - 1)]
                LocalPageView(url: page.1, readAccess: folder, notchInside: page.1.lastPathComponent == "index.html")
                    .frame(height: 760)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .id(page.1)
            }
        }
    }
}

/// A WKWebView limited to one local folder (no network is needed or requested).
struct LocalPageView: NSViewRepresentable {
    let url: URL
    let readAccess: URL
    /// index.html: always use the "Inside notch" collapsed style and hide the style picker.
    var notchInside = false

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        if notchInside {
            let js = "document.addEventListener('DOMContentLoaded',function(){var b=document.querySelector('.seg [data-style=\"inside\"]');if(b)b.click();var s=document.querySelector('.seg');if(s)s.style.display='none';});"
            cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.underPageBackgroundColor = .black
        v.loadFileURL(url, allowingReadAccessTo: readAccess)
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(root: readAccess) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let root: URL
        init(root: URL) { self.root = root }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            // Only pages inside the pack folder.
            if let u = action.request.url, u.isFileURL, u.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

// MARK: - Native preview (packs without HTML pages, e.g. Mochi)

struct NativeCharacterPreview: View {
    let pack: CharacterPack
    @State private var state: CharacterState = .idle
    @State private var serial = 0
    @State private var alt = false
    @State private var gone = false
    @State private var reduce = false
    @State private var on = true
    @State private var expanded = true
    @State private var demo = false
    @State private var tick = 0

    private var frame: CharacterFrame {
        CharacterFrame(state: state, alt: alt, gone: gone, serial: serial, stills: reduce || Look.shared.reduceMotion, clones: 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                // Expanded island.
                ZStack(alignment: .leading) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 30, bottomTrailingRadius: 30, style: .continuous).fill(Color.black)
                    HStack(spacing: 10) {
                        if on && !gone {
                            CharacterRig(frame: frame, pack: pack).frame(width: 124, height: 120)
                                .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottom)))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(state == .movie ? "Cinema mode" : "Glance").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                            Text(state.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            Text(state.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(3)
                        }
                        .padding(.trailing, 18)
                        .padding(.leading, on && !gone ? 0 : 22)
                    }
                }
                .frame(width: 380, height: expanded ? 120 : 32)
                .clipped()
                .animation(IslandModel.openSpring, value: expanded)
                .animation(IslandModel.openSpring, value: gone)
                .onTapGesture { expanded.toggle() }
                // Collapsed notch, "inside notch" style.
                ZStack(alignment: .leading) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous).fill(Color.black)
                    if on && !gone {
                        CharacterRig(frame: frame, pack: pack).frame(width: 31, height: 30).padding(.leading, 10)
                            .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                }
                .frame(width: 200, height: 32)
                .animation(IslandModel.openSpring, value: gone)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(CharacterState.allCases) { s in
                    Button { demo = false; set(s) } label: {
                        Text(s.title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(state == s ? .accentColor : nil)
                }
            }
            HStack(spacing: 16) {
                Toggle("Auto demo", isOn: $demo)
                Toggle("Expanded", isOn: $expanded)
                Toggle("Reduce motion", isOn: $reduce)
                Toggle("Character on", isOn: $on)
            }
            .toggleStyle(.switch).controlSize(.small)
            Text(on ? "\(pack.name): \(state.detail)" : "Character is off. Glance works exactly as it does today.")
                .font(.caption).foregroundStyle(.secondary)
        }
        // Ticks every 1.2 s, only while the Settings window can be seen.
        .task(id: SettingsWindowState.shared.visible) {
            guard SettingsWindowState.shared.visible else { return }
            while true {
                try? await Task.sleep(for: .seconds(1.2))
                if Task.isCancelled { return }
                tick += 1
                if demo, tick % 3 == 0 {
                    let all = CharacterState.allCases
                    set(all[((all.firstIndex(of: state) ?? 0) + 1) % all.count])
                }
                if state == .idle { alt = tick % 7 >= 5 }
            }
        }
        .onChange(of: reduce) { _, _ in serial += 1 }
    }

    private func set(_ s: CharacterState) {
        state = s; serial += 1; gone = false; alt = false
        if s == .movie {
            let my = serial
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0.05 : 1.45)) { if serial == my && state == .movie { gone = true } }
        }
        if s == .finished && !demo {
            let my = serial
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { if serial == my && state == .finished && !demo { set(.idle) } }
        }
    }
}

// MARK: - Settings › Touch Bar

struct CharacterTouchBarSettingsSection: View {
    @Bindable private var settings = AppSettings.shared
    var body: some View {
        Section("Character on the Touch Bar") {
            if TouchBarAPI.available {
                Toggle("Show the character in the Touch Bar", isOn: $settings.prefs.character.touchBar)
                Text("While music plays, Claude Code works or needs you, a file lands on the Shelf or a meeting is close. Deny and Approve on the bar answer Claude like the island buttons. The close box on the left returns to the normal Touch Bar.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This Mac has no Touch Bar. The preview shows what Touch Bar Macs see.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Touch Bar Preview") { CharacterTouchBar.shared.showPreview() }
        }
    }
}
