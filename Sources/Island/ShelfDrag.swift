import AppKit
import SwiftUI

/// Click, drag-out and right-click for one Shelf tile. An AppKit dragging source instead of
/// SwiftUI's `.onDrag`, because only AppKit says how a drag ended: dropped somewhere (the item
/// may leave the Shelf) or cancelled (it always stays).
struct ShelfDragArea: NSViewRepresentable {
    let item: ShelfItem
    var onHover: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> ShelfDragView {
        let v = ShelfDragView()
        v.item = item
        v.onHover = onHover
        return v
    }

    func updateNSView(_ v: ShelfDragView, context: Context) {
        v.item = item
        v.onHover = onHover
        v.toolTip = item.lastPath ?? item.text ?? item.name
    }
}

final class ShelfDragView: NSView, NSDraggingSource {
    var item: ShelfItem?
    var onHover: (Bool) -> Void = { _ in }
    private var downEvent: NSEvent?
    private var dragStarted = false
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let down = downEvent, let item else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        dragStarted = true
        let shelf = ShelfStore.shared
        let dragItem = NSDraggingItem(pasteboardWriter: shelf.pasteboardWriter(for: item))
        let image = shelf.thumbnails[item.id] ?? Self.symbolImage(for: item)
        let side: CGFloat = 56
        let frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        dragItem.setDraggingFrame(frame, contents: image)
        beginDraggingSession(with: [dragItem], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard !dragStarted, let item else { return }
        ShelfStore.shared.open(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping @MainActor () -> Void) {
            let m = ClosureMenuItem(title: title, action: action)
            menu.addItem(m)
        }
        let shelf = ShelfStore.shared
        add("Open") { shelf.open(item) }
        if item.kind == .file || item.kind == .image { add("Quick Look") { shelf.quickLook(item) } }
        if item.kind == .file { add("Show in Finder") { shelf.reveal(item) } }
        if AirDrop.available { add("AirDrop…") { AirDrop.send(shelfItem: item) } } // MARK: feat/system-media
        add(item.pinned ? "Unpin" : "Pin (keep after dragging out)") { shelf.togglePin(item) }
        menu.addItem(.separator())
        add("Remove from Shelf") { shelf.remove(item) }
        return menu
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy only: Finder never moves the original. Not onto Glance itself.
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragStarted = false
        downEvent = nil
        // Empty operation = cancelled, or dropped where nothing accepted it: the item stays.
        guard !operation.isEmpty, let item else { return }
        MainActor.assumeIsolated { ShelfStore.shared.draggedOut(item) }
    }

    private static func symbolImage(for item: ShelfItem) -> NSImage {
        let name = item.kind == .link ? "link" : (item.kind == .text ? "text.alignleft" : "doc")
        let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) ?? NSImage()
    }
}

/// NSMenuItem that runs a closure (for menus built on the fly).
final class ClosureMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { MainActor.assumeIsolated { run() } }
}
