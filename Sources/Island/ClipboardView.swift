import AppKit
import SwiftUI

struct ClipboardView: View {
    let theme: Theme
    private let store = ClipboardStore.shared
    @State private var query = ""
    @State private var composing = false
    @State private var newTitle = ""
    @State private var newText = ""
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool

    private func matches(_ i: ClipItem) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return i.displayTitle.lowercased().contains(q) || (i.text?.lowercased().contains(q) ?? false)
            || (i.paths ?? []).contains { $0.lowercased().contains(q) } || (i.sourceApp?.lowercased().contains(q) ?? false)
    }

    var body: some View {
        let saved = store.saved.filter(matches)
        let history = store.history.filter(matches)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.secondary)
                    TextField("Search clipboard", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.primary)
                        .focused($searchFocused)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.tertiary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(searchFocused ? theme.accent.opacity(0.8) : .clear, lineWidth: 1.2))
                .animation(.easeOut(duration: 0.15), value: searchFocused)

                if AppSettings.shared.prefs.clipboardPaused {
                    Label("Paused", systemImage: "pause.circle").font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                }
                pillButton(composing ? "Cancel" : "New Snippet", symbol: composing ? "xmark" : "square.and.pencil") {
                    withAnimation(IslandModel.openSpring) { composing.toggle(); newTitle = ""; newText = "" }
                }
                pillButton(confirmClear ? "Clear all history?" : "Clear History", symbol: "trash", tint: confirmClear ? .red : nil) {
                    if confirmClear {
                        withAnimation(IslandModel.openSpring) { store.clearHistory() }
                        confirmClear = false
                    } else {
                        confirmClear = true
                        Task { try? await Task.sleep(for: .seconds(3)); confirmClear = false }
                    }
                }
                .disabled(store.history.isEmpty)
                .opacity(store.history.isEmpty ? 0.4 : 1)
            }

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if composing { composer }
                    if !saved.isEmpty {
                        header("Saved", count: saved.count)
                        ForEach(saved) { row($0, saved: true) }
                    }
                    header("History", count: history.count)
                    if history.isEmpty {
                        Text(query.isEmpty ? "Things you copy appear here. Passwords and concealed items are never stored." : "No matches")
                            .font(.system(size: 11)).foregroundStyle(theme.tertiary)
                            .padding(.vertical, 8).padding(.horizontal, 8)
                    }
                    ForEach(history) { row($0, saved: false) }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.automatic)
        }
        .onAppear {
            if IslandModel.shared.openedByHotkey { searchFocused = true }
            ClipQuickPaste.shared.attach() // MARK: feat/system-media
        }
        .onDisappear { ClipQuickPaste.shared.detach() } // MARK: feat/system-media
        .onChange(of: query, initial: true) { _, q in ClipQuickPaste.shared.query = q } // MARK: feat/system-media
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name (optional)", text: $newTitle)
                .textFieldStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.primary)
            TextField("Snippet text", text: $newText, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(theme.primary)
                .lineLimit(2...5)
            HStack {
                Spacer()
                pillButton("Save Snippet", symbol: "pin.fill", tint: .green) {
                    store.addSnippet(title: newTitle, text: newText)
                    withAnimation(IslandModel.openSpring) { composing = false }
                }
                .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card))
        .padding(.bottom, 4)
    }

    private func header(_ t: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(t.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(theme.tertiary)
            Text("\(count)").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(theme.tertiary)
        }
        .padding(.top, 6).padding(.horizontal, 8)
    }

    @ViewBuilder
    private func row(_ item: ClipItem, saved: Bool) -> some View {
        ClipRow(item: item, saved: saved, theme: theme,
                renaming: renaming == item.id, renameText: $renameText,
                onRenameStart: { renaming = item.id; renameText = item.title ?? item.preview },
                onRenameCommit: { store.rename(item, to: renameText); renaming = nil })
    }

    private func pillButton(_ title: String, symbol: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tint ?? theme.primary)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(theme.card))
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct ClipRow: View {
    let item: ClipItem
    let saved: Bool
    let theme: Theme
    let renaming: Bool
    @Binding var renameText: String
    let onRenameStart: () -> Void
    let onRenameCommit: () -> Void
    @State private var hover = false
    private let store = ClipboardStore.shared

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if let t = store.thumbnail(for: item) {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                } else if AppSettings.shared.prefs.clipExtras, item.kind == .text, let c = ClipTools.color(from: item.text ?? "") { // MARK: feat/system-media
                    ClipSwatch(color: c)
                } else {
                    Image(systemName: item.symbol).font(.system(size: 11)).foregroundStyle(saved ? theme.accent : theme.secondary)
                }
            }
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.card))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            if renaming {
                TextField("Name", text: $renameText, onCommit: onRenameCommit)
                    .textFieldStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.primary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.displayTitle).font(.system(size: 12, weight: saved ? .semibold : .regular))
                        .foregroundStyle(theme.primary).lineLimit(1)
                    if saved, item.title?.isEmpty == false {
                        Text(item.preview).font(.system(size: 10)).foregroundStyle(theme.tertiary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 6)
            if hover || renaming {
                HStack(spacing: 2) {
                    if saved {
                        action(renaming ? "checkmark" : "pencil", renaming ? "Done" : "Rename") { renaming ? onRenameCommit() : onRenameStart() }
                        action("chevron.up", "Move up") { withAnimation(IslandModel.openSpring) { store.moveSaved(item, by: -1) } }
                        action("chevron.down", "Move down") { withAnimation(IslandModel.openSpring) { store.moveSaved(item, by: 1) } }
                    } else {
                        action("pin", "Save permanently") { withAnimation(IslandModel.openSpring) { store.save(item) } }
                    }
                    ClipExtrasActions(item: item, theme: theme) // MARK: feat/system-media
                    action("xmark", "Delete") { withAnimation(IslandModel.openSpring) { store.delete(item) } }
                }
                .transition(.opacity)
            } else {
                ClipNumberBadge(item: item, theme: theme) // MARK: feat/system-media
                Text(meta).font(.system(size: 10)).foregroundStyle(theme.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.card.opacity(hover ? 1.4 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { if !renaming { store.use(item) } }
        .contextMenu { ClipExtrasMenu(item: item) } // MARK: feat/system-media
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(item.kind == .files ? (item.paths ?? []).joined(separator: "\n") : "Click to copy")
    }

    private var meta: String {
        let age = -item.date.timeIntervalSinceNow
        let rel: String
        if age < 60 { rel = "now" }
        else if age < 3600 { rel = "\(Int(age / 60))m" }
        else if age < 86400 { rel = "\(Int(age / 3600))h" }
        else { rel = item.date.formatted(.dateTime.day().month(.abbreviated)) }
        if let s = item.sourceApp, !saved { return "\(s) · \(rel)" }
        return saved ? "" : rel
    }

    private func action(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.secondary)
                .frame(width: 22, height: 22).background(Circle().fill(theme.card))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
