import AppKit
import SwiftUI
import Observation

// MARK: feat/productivity - Quick notes (local only, autosaved, owner-only file)

struct QuickNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text = ""
    var updated = Date()
    var title: String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return first.isEmpty ? "New note" : String(first.prefix(40))
    }
}

@Observable @MainActor
final class NotesStore {
    static let shared = NotesStore()
    var notes: [QuickNote] = []
    var selected: UUID?
    private(set) var lastSaved: Date?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loaded = false

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        notes = ToolsStore.read([QuickNote].self, "notes.json") ?? []
        notes.sort { $0.updated > $1.updated }
        selected = notes.first?.id
    }

    func add() {
        let n = QuickNote()
        notes.insert(n, at: 0)
        selected = n.id
        scheduleSave()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        if selected == id { selected = notes.first?.id }
        scheduleSave()
    }

    func edit(_ id: UUID, _ text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].updated = Date()
        scheduleSave()
    }

    /// Debounced autosave: writes 0.6 s after the last keystroke, off the main thread.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let d = try? JSONEncoder().encode(notes) else { return }
        ToolsStore.write(d, to: ToolsStore.url("notes.json"))
        lastSaved = Date()
    }
}

struct NotesView: View {
    let theme: Theme
    private let store = NotesStore.shared
    @FocusState private var editorFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 6) {
                Button { store.add(); editorFocused = true } label: {
                    Label("New note", systemImage: "plus").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.onAccent).frame(maxWidth: .infinity).frame(height: 26)
                        .background(Capsule().fill(theme.accent))
                }.buttonStyle(PressScaleStyle())
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(store.notes) { n in
                            Button { store.selected = n.id; editorFocused = true } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(n.title).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.primary).lineLimit(1)
                                    Text(n.updated.formatted(.relative(presentation: .named))).font(.system(size: 9)).foregroundStyle(theme.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).frame(height: 36)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(store.selected == n.id ? theme.accent.opacity(0.22) : theme.card))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Delete", role: .destructive) { store.delete(n.id) } }
                        }
                    }
                }
            }
            .frame(width: 170)

            VStack(alignment: .leading, spacing: 6) {
                if let id = store.selected, let i = store.notes.firstIndex(where: { $0.id == id }) {
                    TextEditor(text: Binding(get: { store.notes.indices.contains(i) ? store.notes[i].text : "" }, set: { store.edit(id, $0) }))
                        .font(.system(size: 12)).foregroundStyle(theme.primary)
                        .scrollContentBackground(.hidden)
                        .focused($editorFocused)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(editorFocused ? theme.accent.opacity(0.7) : .clear, lineWidth: 1.2))
                    HStack {
                        Text(store.lastSaved.map { "Saved \($0.formatted(date: .omitted, time: .shortened)) · stored only on this Mac" } ?? "Autosaves as you type · stored only on this Mac")
                            .font(.system(size: 9)).foregroundStyle(theme.tertiary)
                        Spacer()
                        Button { store.delete(id) } label: { Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(theme.secondary) }
                            .buttonStyle(.plain).help("Delete note")
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "note.text").font(.system(size: 22)).foregroundStyle(theme.tertiary)
                        Text("No notes yet. Press New note.").font(.system(size: 11)).foregroundStyle(theme.tertiary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { store.loadIfNeeded() }
        .onDisappear { store.saveNow() }
    }
}
