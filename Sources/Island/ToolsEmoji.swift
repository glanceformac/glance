import AppKit
import SwiftUI
import Observation

// MARK: feat/productivity - Emoji picker (names come from the Unicode database built into Swift)

@Observable @MainActor
final class EmojiCatalog {
    static let shared = EmojiCatalog()
    struct Item: Identifiable, Hashable { let id: String; let name: String; var emoji: String { id } }
    private(set) var items: [Item] = []
    private(set) var loaded = false
    @ObservationIgnored private var loading = false

    nonisolated private static let aliases: [String: String] = [
        "😂": "lol laugh funny haha", "🤣": "rofl lol laugh", "👍": "ok yes good like approve thumbs up", "👎": "no bad dislike thumbs down",
        "❤️": "love heart red", "🔥": "fire hot lit", "🎉": "party celebrate congrats tada", "🙏": "please thanks pray",
        "😭": "cry sad sob", "😍": "love eyes heart", "🤔": "think hmm", "👀": "eyes look", "✅": "done tick check yes",
        "❌": "no cross wrong", "⭐": "star favourite", "🚀": "rocket launch ship", "💡": "idea bulb", "☕": "coffee tea",
        "🍕": "pizza food", "🐛": "bug", "💀": "dead skull", "😊": "smile happy", "😎": "cool sunglasses", "🙌": "praise hands yay",
        "👏": "clap applause", "💪": "strong muscle", "🌍": "world earth globe", "⚽": "football soccer", "🏆": "trophy win",
    ]

    func loadIfNeeded() {
        guard !loaded, !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let built = Self.build()
            await MainActor.run {
                self.items = built
                self.loaded = true
                self.loading = false
            }
        }
    }

    nonisolated private static func build() -> [Item] {
        var out: [Item] = []
        let ranges: [ClosedRange<UInt32>] = [0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x2600...0x27BF, 0x2B00...0x2BFF, 0x1F000...0x1F2FF]
        let skip = Set<UInt32>([0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF])  // skin-tone modifiers on their own
        for r in ranges {
            for v in r {
                guard let s = Unicode.Scalar(v), !skip.contains(v) else { continue }
                let p = s.properties
                guard p.isEmojiPresentation || (p.isEmoji && Self.textEmoji.contains(v)) else { continue }
                var str = String(s)
                if !p.isEmojiPresentation { str += "\u{FE0F}" }
                let name = (p.name ?? "").lowercased()
                guard !name.isEmpty else { continue }
                out.append(Item(id: str, name: name + (aliases[str].map { " " + $0 } ?? "")))
            }
        }
        return out
    }

    /// Text-presentation emoji worth showing (hearts, weather, hands, arrows...).
    nonisolated private static let textEmoji: Set<UInt32> = [0x2600, 0x2601, 0x2602, 0x2603, 0x2604, 0x260E, 0x2611, 0x2614, 0x2615, 0x2618, 0x261D, 0x2620, 0x2622, 0x2623, 0x2626, 0x262A, 0x262E, 0x262F, 0x2638, 0x2639, 0x263A, 0x2640, 0x2642, 0x2648, 0x2649, 0x264A, 0x264B, 0x264C, 0x264D, 0x264E, 0x264F, 0x2650, 0x2651, 0x2652, 0x2653, 0x265F, 0x2660, 0x2663, 0x2665, 0x2666, 0x2668, 0x267B, 0x267E, 0x267F, 0x2692, 0x2693, 0x2694, 0x2695, 0x2696, 0x2697, 0x2699, 0x269B, 0x269C, 0x26A0, 0x26A1, 0x26A7, 0x26AA, 0x26AB, 0x26B0, 0x26B1, 0x26BD, 0x26BE, 0x26C4, 0x26C5, 0x26C8, 0x26CE, 0x26CF, 0x26D1, 0x26D3, 0x26D4, 0x26E9, 0x26EA, 0x26F0, 0x26F1, 0x26F2, 0x26F3, 0x26F4, 0x26F5, 0x26F7, 0x26F8, 0x26F9, 0x26FA, 0x26FD, 0x2702, 0x2705, 0x2708, 0x2709, 0x270A, 0x270B, 0x270C, 0x270D, 0x270F, 0x2712, 0x2714, 0x2716, 0x271D, 0x2721, 0x2728, 0x2733, 0x2734, 0x2744, 0x2747, 0x274C, 0x274E, 0x2753, 0x2754, 0x2755, 0x2757, 0x2763, 0x2764, 0x2795, 0x2796, 0x2797, 0x27A1, 0x27B0, 0x27BF, 0x2B05, 0x2B06, 0x2B07, 0x2B1B, 0x2B1C, 0x2B50, 0x2B55]

    func search(_ q: String) -> [Item] {
        let words = q.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { it in words.allSatisfy { it.name.contains($0) } }
    }
}

struct EmojiView: View {
    let theme: Theme
    private let catalog = EmojiCatalog.shared
    private let prefs = ToolsPrefs.shared
    @Bindable private var vs = ToolsViewState.shared
    private var query: String { get { vs.emojiQuery } nonmutating set { vs.emojiQuery = newValue } }
    @State private var copied: String?
    @FocusState private var focused: Bool

    private let cols = Array(repeating: GridItem(.fixed(34), spacing: 4), count: 16)

    var body: some View {
        let results = catalog.search(query)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ToolField(theme: theme, placeholder: "Search emoji by name, e.g. heart, fire, party", text: $vs.emojiQuery, focus: $focused) {
                    if let first = results.first { choose(first.emoji) }
                }
                Text(copied.map { "Copied \($0)" } ?? (AppSettings.shared.prefs.pasteAfterCopy ? "Click to paste" : "Click to copy"))
                    .font(.system(size: 11)).foregroundStyle(theme.secondary)
            }
            if query.isEmpty, !prefs.data.recentEmoji.isEmpty {
                HStack(spacing: 4) {
                    Text("Recent").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.tertiary).padding(.trailing, 2)
                    ForEach(prefs.data.recentEmoji.prefix(14), id: \.self) { e in cell(e) }
                    Spacer()
                }
            }
            ScrollView {
                if !catalog.loaded {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(20)
                } else if results.isEmpty {
                    Text("No emoji match \"\(query)\"").font(.system(size: 11)).foregroundStyle(theme.tertiary).padding(14)
                } else {
                    LazyVGrid(columns: cols, spacing: 4) {
                        ForEach(results.prefix(600)) { it in cell(it.emoji).help(it.name) }
                    }
                    .padding(.bottom, 18)   // the last row clears the panel's rounded bottom edge
                }
            }
            // A partly visible row fades out instead of being cut by a hard edge.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .padding(.bottom, 6)
        }
        .onAppear { focused = true; catalog.loadIfNeeded() }
    }

    private func cell(_ e: String) -> some View {
        Button { choose(e) } label: {
            Text(e).font(.system(size: 21)).frame(width: 34, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(copied == e ? theme.accent.opacity(0.3) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(EmojiCellStyle(theme: theme))
    }

    private func choose(_ e: String) {
        copied = e
        var r = prefs.data.recentEmoji
        r.removeAll { $0 == e }
        r.insert(e, at: 0)
        prefs.data.recentEmoji = Array(r.prefix(24))
        let pb = Env.pasteboard
        pb.clearContents()
        pb.setString(e, forType: .string)
        ClipboardStore.shared.noteOwnWrite()
        Feedback.sound("Tink")
        let wantsPaste = AppSettings.shared.prefs.pasteAfterCopy && !Env.noPermissions && AXIsProcessTrusted()
        if wantsPaste {
            IslandModel.shared.setExpanded(false)
            Task { try? await Task.sleep(for: .milliseconds(180)); ClipboardStore.postCommandV() }
        }
    }
}

struct EmojiCellStyle: ButtonStyle {
    let theme: Theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.card.opacity(configuration.isPressed ? 2 : 0)))
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
