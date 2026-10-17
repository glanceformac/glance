import AppKit
import SwiftUI

// MARK: feat/productivity - Quick web search (opens in the default browser; nothing is sent from Glance itself)

struct SearchEngine: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let template: String   // %@ is the percent-encoded query
}

enum SearchEngines {
    static let all: [SearchEngine] = [
        SearchEngine(id: "google", name: "Google", symbol: "g.circle", template: "https://www.google.com/search?q=%@"),
        SearchEngine(id: "ddg", name: "DuckDuckGo", symbol: "shield", template: "https://duckduckgo.com/?q=%@"),
        SearchEngine(id: "bing", name: "Bing", symbol: "b.circle", template: "https://www.bing.com/search?q=%@"),
        SearchEngine(id: "perplexity", name: "Perplexity", symbol: "sparkle.magnifyingglass", template: "https://www.perplexity.ai/search?q=%@"),
        SearchEngine(id: "youtube", name: "YouTube", symbol: "play.rectangle", template: "https://www.youtube.com/results?search_query=%@"),
        SearchEngine(id: "github", name: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", template: "https://github.com/search?q=%@"),
        SearchEngine(id: "wikipedia", name: "Wikipedia", symbol: "w.circle", template: "https://en.wikipedia.org/w/index.php?search=%@"),
        SearchEngine(id: "maps", name: "Maps", symbol: "map", template: "https://www.google.com/maps/search/?api=1&query=%@"),
        SearchEngine(id: "amazon", name: "Amazon", symbol: "cart", template: "https://www.amazon.co.uk/s?k=%@"),
    ]

    static func url(engine: SearchEngine, query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?/")
        guard let q = query.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: allowed), !q.isEmpty else { return nil }
        return URL(string: engine.template.replacingOccurrences(of: "%@", with: q))
    }
}

struct WebSearchView: View {
    let theme: Theme
    private let prefs = ToolsPrefs.shared
    @State private var query = ""
    @FocusState private var focused: Bool

    private var engine: SearchEngine { SearchEngines.all.first { $0.id == prefs.data.searchEngine } ?? SearchEngines.all[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolField(theme: theme, placeholder: "Search \(engine.name) and press Return", text: $query, symbol: engine.symbol, focus: $focused) { go() }
            Text("Pick an engine with Command 1 to 9").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.tertiary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Array(SearchEngines.all.enumerated()), id: \.element.id) { i, e in
                    Button { prefs.data.searchEngine = e.id; focused = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: e.symbol).font(.system(size: 12)).frame(width: 16)
                            Text(e.name).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("⌘\(i + 1)").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(theme.tertiary)
                        }
                        .foregroundStyle(e.id == engine.id ? theme.primary : theme.secondary)
                        .padding(.horizontal, 10).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(e.id == engine.id ? theme.accent.opacity(0.22) : theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(e.id == engine.id ? theme.accent.opacity(0.55) : .clear, lineWidth: 1))
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
            Spacer(minLength: 0)
            Text("Opens in your default browser. Glance does not see your results.").font(.system(size: 9)).foregroundStyle(theme.tertiary)
        }
        .background {
            // Command-1 ... Command-9 pick the engine while this tab is open.
            ZStack {
                ForEach(Array(SearchEngines.all.enumerated()), id: \.element.id) { i, e in
                    Button("") { prefs.data.searchEngine = e.id; focused = true }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }.opacity(0).allowsHitTesting(false)
        }
        .onAppear { focused = true }
    }

    private func go() {
        guard let url = SearchEngines.url(engine: engine, query: query) else { return }
        NSWorkspace.shared.open(url)
        query = ""
        IslandModel.shared.setExpanded(false)
    }
}
