import AppKit
import SwiftUI
import Observation
import ApplicationServices

// MARK: - AirDrop (Shelf and screenshots)

@MainActor
enum AirDrop {
    /// NSSharingService .sendViaAirDrop (public). Opens the system AirDrop picker.
    static var service: NSSharingService? { NSSharingService(named: .sendViaAirDrop) }

    static func canSend(_ items: [Any]) -> Bool { service?.canPerform(withItems: items) ?? false }
    static var available: Bool { service != nil }

    static func send(urls: [URL]) {
        guard !urls.isEmpty, let s = service, s.canPerform(withItems: urls) else {
            IslandModel.shared.enqueue(Peek(symbol: "exclamationmark.triangle", title: "AirDrop unavailable", subtitle: "Turn on Wi-Fi and Bluetooth", tint: .orange))
            return
        }
        IslandModel.shared.setExpanded(false)
        NSApp.activate(ignoringOtherApps: true)
        s.perform(withItems: urls)
    }

    /// AirDrop does not accept bare strings, so the text goes as a small .txt file in Glance's own cache.
    static func send(text: String) {
        let dir = Env.cachesBase.appendingPathComponent("Glance/airdrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(24)) } ?? "Text"
        let safe = first.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(safe).txt")
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        send(urls: [url])
    }

    /// What a Shelf item hands to the sharing service.
    static func send(shelfItem item: ShelfItem) {
        let shelf = ShelfStore.shared
        switch item.kind {
        case .file, .image:
            if let u = shelf.url(for: item) { send(urls: [u]) }
        case .link:
            if let u = shelf.url(for: item), let s = service, s.canPerform(withItems: [u]) {
                IslandModel.shared.setExpanded(false); NSApp.activate(ignoringOtherApps: true); s.perform(withItems: [u])
            } else if let t = item.text { send(text: t) }
        case .text:
            send(text: item.text ?? item.name)
        }
    }
}

// MARK: - Clipboard helpers (pure functions, testable)

enum ClipTools {
    /// Query parameters that only track you. utm_* is matched by prefix.
    static let trackingKeys: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "igshid", "mc_cid", "mc_eid",
        "_hsenc", "_hsmi", "mkt_tok", "twclid", "ttclid", "li_fat_id", "vero_id", "oly_enc_id", "oly_anon_id",
    ]

    /// Returns the URL without tracking parameters, or nil when nothing needed removing / not a web link.
    static func stripTracking(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where: \.isWhitespace), var c = URLComponents(string: t),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let items = c.percentEncodedQueryItems, !items.isEmpty else { return nil }
        let kept = items.filter { i in
            let k = i.name.lowercased()
            return !(k.hasPrefix("utm_") || trackingKeys.contains(k))
        }
        guard kept.count != items.count else { return nil }
        c.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return c.string
    }

    /// Plain text: no rich formatting, trimmed.
    static func plain(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A whole string that is a colour: #RGB #RGBA #RRGGBB #RRGGBBAA, rgb()/rgba(), hsl()/hsla().
    static func color(from raw: String) -> NSColor? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.count >= 4, s.count <= 48 else { return nil }
        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            func comp(_ a: Int, _ len: Int) -> CGFloat {
                let sub = hex[hex.index(hex.startIndex, offsetBy: a)..<hex.index(hex.startIndex, offsetBy: a + len)]
                let v = Int(len == 1 ? sub + sub : sub, radix: 16) ?? 0
                return CGFloat(v) / 255
            }
            switch hex.count {
            case 3: return NSColor(srgbRed: comp(0, 1), green: comp(1, 1), blue: comp(2, 1), alpha: 1)
            case 4: return NSColor(srgbRed: comp(0, 1), green: comp(1, 1), blue: comp(2, 1), alpha: comp(3, 1))
            case 6: return NSColor(srgbRed: comp(0, 2), green: comp(2, 2), blue: comp(4, 2), alpha: 1)
            case 8: return NSColor(srgbRed: comp(0, 2), green: comp(2, 2), blue: comp(4, 2), alpha: comp(6, 2))
            default: return nil
            }
        }
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
        let fn = String(s[..<open]).trimmingCharacters(in: .whitespaces)
        let body = s[s.index(after: open)..<s.index(before: s.endIndex)]
        let nums = body.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map { String($0) }
        func num(_ x: String) -> CGFloat? {
            let isPct = x.hasSuffix("%")
            guard let v = Double(isPct ? String(x.dropLast()) : x.replacingOccurrences(of: "deg", with: "")) else { return nil }
            return CGFloat(v)
        }
        switch fn {
        case "rgb", "rgba":
            guard nums.count == 3 || nums.count == 4 else { return nil }
            let v = nums.prefix(3).compactMap { n -> CGFloat? in
                guard let x = num(n) else { return nil }
                return n.hasSuffix("%") ? x / 100 : x / 255
            }
            guard v.count == 3, v.allSatisfy({ $0 >= 0 && $0 <= 1.0001 }) else { return nil }
            var a: CGFloat = 1
            if nums.count == 4, let x = num(nums[3]) { a = nums[3].hasSuffix("%") ? x / 100 : x }
            return NSColor(srgbRed: v[0], green: v[1], blue: v[2], alpha: min(max(a, 0), 1))
        case "hsl", "hsla":
            guard nums.count == 3 || nums.count == 4, let h = num(nums[0]), let sat = num(nums[1]), let l = num(nums[2]),
                  sat >= 0, sat <= 100, l >= 0, l <= 100 else { return nil }
            let S = sat / 100, L = l / 100
            // HSL -> HSB
            let B = L + S * min(L, 1 - L)
            let Sb = B == 0 ? 0 : 2 * (1 - L / B)
            var a: CGFloat = 1
            if nums.count == 4, let x = num(nums[3]) { a = nums[3].hasSuffix("%") ? x / 100 : x }
            return NSColor(hue: (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360, saturation: Sb, brightness: B, alpha: min(max(a, 0), 1))
        default: return nil
        }
    }

    static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02X%02X%02X", Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()), Int((s.blueComponent * 255).rounded()))
    }
}

// MARK: - Quick paste 1 to 9 (Clipboard tab)

/// Saved snippets then history, in the order the tab shows them. Press 1 to 9 (or Command+1 to 9
/// while the search box has focus) to paste that item.
@Observable @MainActor
final class ClipQuickPaste {
    static let shared = ClipQuickPaste()
    var query = ""
    @ObservationIgnored private var monitor: Any?

    var enabled: Bool { AppSettings.shared.prefs.clipExtras }

    private func matches(_ i: ClipItem) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return i.displayTitle.lowercased().contains(q) || (i.text?.lowercased().contains(q) ?? false)
            || (i.paths ?? []).contains { $0.lowercased().contains(q) } || (i.sourceApp?.lowercased().contains(q) ?? false)
    }

    var numbered: [ClipItem] {
        let s = ClipboardStore.shared
        return Array((s.saved.filter(matches) + s.history.filter(matches)).prefix(9))
    }

    func number(for item: ClipItem) -> Int? {
        guard enabled else { return nil }
        return numbered.firstIndex(where: { $0.id == item.id }).map { $0 + 1 }
    }

    func attach() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let h = MainActor.assumeIsolated { ClipQuickPaste.shared.handle(e) }; return h ? nil : e
        }
    }

    func detach() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func handle(_ e: NSEvent) -> Bool {
        guard enabled, IslandModel.shared.expanded, IslandModel.shared.page == .clipboard,
              let ch = e.charactersIgnoringModifiers, ch.count == 1, let n = Int(ch), (1...9).contains(n) else { return false }
        let typing = (e.window?.firstResponder as? NSTextView)?.isEditable ?? false
        let cmd = e.modifierFlags.contains(.command)
        // While typing in the search box only Command+digit pastes; otherwise a plain digit does.
        guard cmd || !typing else { return false }
        guard e.modifierFlags.intersection([.control, .option]).isEmpty else { return false }
        return paste(n)
    }

    @discardableResult
    func paste(_ n: Int) -> Bool {
        let list = numbered
        guard n >= 1, n <= list.count else { return false }
        ClipExtras.paste(list[n - 1], plain: false)
        return true
    }
}

@MainActor
enum ClipExtras {
    /// Put the item on the pasteboard (optionally as plain text only) and paste it into the front app
    /// when Accessibility is already granted; otherwise it is just copied.
    static func paste(_ item: ClipItem, plain: Bool) {
        let store = ClipboardStore.shared
        if plain, let t = item.text {
            let pb = Env.pasteboard
            pb.clearContents()
            pb.setString(ClipTools.plain(t), forType: .string)
        } else {
            store.copy(item)
        }
        Feedback.sound("Tink")
        IslandModel.shared.setExpanded(false)
        if !Env.noPermissions && !Env.isolated && AXIsProcessTrusted() {
            Task { try? await Task.sleep(for: .milliseconds(180)); ClipboardStore.postCommandV() }
        } else {
            IslandModel.shared.enqueue(Peek(symbol: "doc.on.doc.fill", title: plain ? "Copied as plain text" : "Copied",
                                            subtitle: String(item.displayTitle.prefix(24)), duration: 1.4))
        }
    }

    static func copyClean(_ item: ClipItem) {
        guard let t = item.text, let clean = ClipTools.stripTracking(t) else { return }
        let pb = Env.pasteboard
        pb.clearContents()
        if let u = URL(string: clean) { pb.writeObjects([u as NSURL]) }
        pb.setString(clean, forType: .string)
        IslandModel.shared.enqueue(Peek(symbol: "scissors", title: "Tracking removed", subtitle: "Clean link copied", tint: .green, duration: 1.8))
    }

    static func copyPlain(_ item: ClipItem) {
        guard let t = item.text else { return }
        let pb = Env.pasteboard
        pb.clearContents()
        pb.setString(ClipTools.plain(t), forType: .string)
        IslandModel.shared.enqueue(Peek(symbol: "textformat", title: "Copied as plain text", duration: 1.6))
    }
}

// MARK: - Row pieces

struct ClipSwatch: View {
    let color: NSColor
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor: color))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
            .accessibilityLabel("Colour \(ClipTools.hex(color))")
    }
}

struct ClipNumberBadge: View {
    let item: ClipItem
    let theme: Theme
    var body: some View {
        if let n = ClipQuickPaste.shared.number(for: item) {
            Text("\(n)").font(.system(size: 9.5, weight: .bold).monospacedDigit()).foregroundStyle(theme.secondary)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(theme.tertiary, lineWidth: 0.7))
                .help("Press \(n) to paste")
        }
    }
}

struct ClipExtrasActions: View {
    let item: ClipItem
    let theme: Theme
    var body: some View {
        if AppSettings.shared.prefs.clipExtras, item.kind == .text || item.kind == .link {
            if item.kind == .link, let t = item.text, ClipTools.stripTracking(t) != nil {
                button("scissors", "Copy link without tracking") { ClipExtras.copyClean(item) }
            }
            button("textformat", "Copy as plain text") { ClipExtras.copyPlain(item) }
        }
    }
    private func button(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.secondary)
                .frame(width: 22, height: 22).background(Circle().fill(theme.card))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ClipExtrasMenu: View {
    let item: ClipItem
    var body: some View {
        if AppSettings.shared.prefs.clipExtras {
            if item.kind == .text || item.kind == .link {
                Button("Paste as Plain Text") { ClipExtras.paste(item, plain: true) }
                Button("Copy as Plain Text") { ClipExtras.copyPlain(item) }
            }
            if item.kind == .link, let t = item.text, ClipTools.stripTracking(t) != nil {
                Button("Copy Link Without Tracking") { ClipExtras.copyClean(item) }
            }
            if item.kind == .text || item.kind == .link, AirDrop.available {
                Button("AirDrop…") { AirDrop.send(text: item.text ?? "") }
            }
        }
    }
}
