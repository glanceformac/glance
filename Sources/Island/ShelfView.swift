import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    let theme: Theme
    private let shelf = ShelfStore.shared
    private let model = IslandModel.shared
    @State private var targeted = false
    @State private var confirmClear = false

    static let dropTypes: [UTType] = [.fileURL, .url, .image, .plainText, .text]

    var body: some View {
        let dropping = targeted || model.shelfDragActive
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Shelf").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.primary)
                Text(shelf.items.isEmpty ? "Drag files, images, text or links onto the island" : "\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s") · drag out to use · right-click for more")
                    .font(.system(size: 11)).foregroundStyle(theme.tertiary).lineLimit(1)
                Spacer()
                if let gone = shelf.pendingUndo {
                    UndoBar(name: gone.name, theme: theme)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                if !shelf.items.isEmpty {
                    Button {
                        if confirmClear { shelf.clear(); confirmClear = false }
                        else { confirmClear = true; Task { try? await Task.sleep(for: .seconds(3)); confirmClear = false } }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash").font(.system(size: 10, weight: .semibold))
                            Text(confirmClear ? "Clear Shelf?" : "Clear All").font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(confirmClear ? Color.red : theme.primary)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(theme.card))
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
            ZStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items) { ShelfTile(item: $0, theme: theme) }
                        DropTile(theme: theme, highlighted: dropping)
                    }
                    .padding(.vertical, 2)
                }
                if dropping {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(theme.dark ? Color(white: 0.13).opacity(0.96) : Color(white: 0.95).opacity(0.96)))
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 26)).foregroundStyle(theme.primary)
                                    .symbolEffect(.bounce, value: targeted)
                                Text("Drop to add to Shelf").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primary)
                            }
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dropping)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: shelf.pendingUndo?.id)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onDrop(of: Self.dropTypes, isTargeted: $targeted) { providers in
            let ok = shelf.add(providers: providers)
            model.shelfDragActive = false
            if ok { Feedback.haptic(.levelChange); Feedback.sound("Pop") }
            return ok
        }
    }
}

struct DropTile: View {
    let theme: Theme
    let highlighted: Bool
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 18, weight: .light)).foregroundStyle(theme.tertiary)
            Text("Drop here").font(.system(size: 10)).foregroundStyle(theme.tertiary)
        }
        .frame(width: 88, height: 112)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(theme.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

/// "Removed · Undo" after a drag out of the Shelf (about 5 seconds).
struct UndoBar: View {
    let name: String
    let theme: Theme
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.up.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.secondary)
            Text("Removed").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.primary)
            Button { ShelfStore.shared.undoRemoval() } label: {
                Text("Undo").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 8).frame(height: 18).background(Capsule().fill(theme.accent))
            }
            .buttonStyle(PressScaleStyle())
            .help("Put \(name) back on the Shelf")
        }
        .padding(.leading, 10).padding(.trailing, 3).frame(height: 24)
        .background(Capsule().fill(theme.card))
    }
}

struct ShelfTile: View {
    let item: ShelfItem
    let theme: Theme
    @State private var swiftUIHover = false
    @State private var tileHover = false
    private var hover: Bool { swiftUIHover || tileHover }
    private let shelf = ShelfStore.shared

    var body: some View {
        let missing = shelf.isMissing(item)
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 6) {
                Group {
                    if let t = shelf.thumbnails[item.id] {
                        Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: item.kind == .link ? "link" : (item.kind == .text ? "text.alignleft" : "doc"))
                            .font(.system(size: 22, weight: .light)).foregroundStyle(theme.secondary)
                    }
                }
                .frame(width: 56, height: 56)
                .opacity(missing ? 0.35 : 1)
                Text(missing ? "Missing: \(item.name)" : item.name)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(missing ? .red : theme.primary)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .frame(width: 80)
            }
            .frame(width: 88, height: 112)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.card.opacity(hover ? 1.6 : 1)))
            // Click opens, drag takes it out (and off the Shelf once dropped), right-click for more.
            .overlay(ShelfDragArea(item: item, onHover: { h in tileHover = h }))
            .scaleEffect(hover ? 1.03 : 1)

            if item.pinned || hover {
                Button { shelf.togglePin(item) } label: {
                    Image(systemName: item.pinned ? "pin.fill" : "pin").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(item.pinned ? theme.onAccent : .white)
                        .rotationEffect(.degrees(45))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(item.pinned ? theme.accent : Color(white: 0.4)))
                }
                .buttonStyle(.plain).offset(x: hover ? -16 : 4, y: -4)
                .help(item.pinned ? "Pinned: stays on the Shelf after dragging out. Click to unpin." : "Pin: keep on the Shelf after dragging out")
                .accessibilityLabel(item.pinned ? "Unpin" : "Pin")
                .transition(.scale.combined(with: .opacity))
            }

            if hover, AirDrop.available { // MARK: feat/system-media
                Button { AirDrop.send(shelfItem: item) } label: {
                    Image(systemName: "dot.radiowaves.up.forward").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 18, height: 18).background(Circle().fill(Color(white: 0.4)))
                }
                .buttonStyle(.plain).offset(x: -64, y: -4)
                .help("AirDrop")
                .transition(.scale.combined(with: .opacity))
            }
            if hover {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, Color(white: 0.4))
                }
                .buttonStyle(.plain).offset(x: 4, y: -4)
                .help("Remove from Shelf")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
        .onHover { swiftUIHover = $0 }
        .onAppear { shelf.loadThumbnail(item) }
    }
}

/// Home | Clipboard | Shelf switch.
struct TabSwitch: View {
    let theme: Theme
    private let model = IslandModel.shared
    @Namespace private var ns

    private var tabs: [(ExpandedPage, String, String)] {
        var t: [(ExpandedPage, String, String)] = [(.widgets, "Home", "house"), (.clipboard, "Clipboard", "doc.on.clipboard"), (.shelf, "Shelf", "tray")]
        if AppSettings.shared.prefs.todoEnabled { t.append((.today, "Today", "checklist")) }
        if AppSettings.shared.prefs.toolsTab { t.append((.tools, "Tools", "wrench.and.screwdriver")) }   // MARK: feat/productivity
        t.append((.system, "System", "gauge.with.dots.needle.50percent")) // MARK: feat/system-media
        return t
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.1) { tab in
                let selected = model.page == tab.0 || (tab.0 == .widgets && (model.page == .volume || model.page == .brightness))
                Button {
                    withAnimation(IslandModel.openSpring) {
                        model.editing = false
                        model.page = tab.0
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.2).font(.system(size: 10, weight: .medium))
                        // Up to 3 tabs: names. 4: only the selected one. More: icons only (names in tooltips).
                        if tabs.count <= 3 || (selected && tabs.count <= 4) { Text(tab.1).font(.system(size: 11, weight: .medium)) }
                        if tab.0 == .shelf, !ShelfStore.shared.items.isEmpty {
                            Text("\(ShelfStore.shared.items.count)").font(.system(size: 9, weight: .bold).monospacedDigit())
                                .foregroundStyle(theme.onAccent)
                                .padding(.horizontal, 4).background(Capsule().fill(theme.accent))
                        }
                    }
                    .foregroundStyle(selected ? theme.primary : theme.secondary)
                    .padding(.horizontal, tabs.count > 4 ? 8 : 10).frame(height: 24) // MARK: feat/system-media (5 tabs need to fit)
                    .background {
                        if selected {
                            Capsule().fill(theme.accent.opacity(theme.dark ? 0.26 : 0.16))
                                .overlay(Capsule().strokeBorder(theme.accent.opacity(0.45), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.1)
                .accessibilityLabel(tab.1)
            }
        }
        .padding(2)
        .background(Capsule().fill(theme.card.opacity(0.6)))
    }
}
