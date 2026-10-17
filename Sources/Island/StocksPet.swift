import AppKit
import SwiftUI
import QuartzCore
import Observation

// MARK: - Stocks ticker (optional, off by default)
//
// Free source: Yahoo Finance's public chart endpoint (no key, no account). Fetched only while the
// Stocks view is on screen, at most once a minute, off the main thread. Quotes can be delayed;
// this is not trading data.

struct StockQuote: Identifiable, Equatable {
    var symbol: String
    var name: String
    var price: Double
    var changePercent: Double
    var currency: String
    var id: String { symbol }
}

@Observable @MainActor
final class StocksService {
    static let shared = StocksService()
    private(set) var quotes: [StockQuote] = []
    private(set) var lastUpdate: Date?
    private(set) var failed = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var visible = 0

    var symbols: [String] {
        AppSettings.shared.prefs.stockSymbols.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.uppercased() }.prefix(8).map { String($0) }
    }

    func setVisible(_ on: Bool) {
        visible = max(0, visible + (on ? 1 : -1))
        if visible > 0 && AppSettings.shared.prefs.stocksEnabled {
            guard timer == nil else { return }
            refresh()
            let t = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { StocksService.shared.refresh() } }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate(); timer = nil
        }
    }

    func refresh() {
        let syms = symbols
        guard !syms.isEmpty else { return }
        Task.detached(priority: .utility) {
            var out: [StockQuote] = []
            for s in syms { if let q = await Self.fetch(s) { out.append(q) } }
            let result = out
            await MainActor.run {
                let me = StocksService.shared
                me.failed = result.isEmpty
                if !result.isEmpty { me.quotes = result; me.lastUpdate = Date() }
            }
        }
    }

    nonisolated static func fetch(_ symbol: String) async -> StockQuote? {
        guard let enc = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(enc)?interval=1d&range=1d") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data, symbol: symbol)
    }

    nonisolated static func parse(_ data: Data, symbol: String) -> StockQuote? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = root["chart"] as? [String: Any], let res = (chart["result"] as? [[String: Any]])?.first,
              let meta = res["meta"] as? [String: Any], let price = (meta["regularMarketPrice"] as? NSNumber)?.doubleValue else { return nil }
        let prev = (meta["chartPreviousClose"] as? NSNumber)?.doubleValue ?? (meta["previousClose"] as? NSNumber)?.doubleValue
        let pct = prev.map { $0 > 0 ? (price - $0) / $0 * 100 : 0 } ?? 0
        return StockQuote(symbol: (meta["symbol"] as? String) ?? symbol, name: (meta["shortName"] as? String) ?? symbol,
                          price: price, changePercent: pct, currency: (meta["currency"] as? String) ?? "")
    }

    func debugSet(_ q: [StockQuote]) { quotes = q; lastUpdate = Date() }
}

struct StocksView: View {
    let theme: Theme
    private let svc = StocksService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !AppSettings.shared.prefs.stocksEnabled {
                note("Off. Turn on in Settings, System & Media, and choose your symbols.")
            } else if svc.quotes.isEmpty {
                note(svc.failed ? "Couldn't load prices. Check your connection." : "Loading prices…")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(svc.quotes) { chip($0) } }
                }
                HStack(spacing: 4) {
                    if let t = svc.lastUpdate { Text("Updated \(t.formatted(date: .omitted, time: .shortened)). Prices can be delayed.") }
                }
                .font(.system(size: 10)).foregroundStyle(theme.tertiary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { svc.setVisible(true) }
        .onDisappear { svc.setVisible(false) }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(theme.tertiary).padding(.top, 14).padding(.horizontal, 8)
    }

    private func chip(_ q: StockQuote) -> some View {
        let up = q.changePercent >= 0
        let c: Color = up ? .green : .red
        return VStack(alignment: .leading, spacing: 3) {
            Text(q.symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(theme.secondary)
            Text(String(format: "%.2f", q.price)).font(.system(size: 18, weight: .semibold).monospacedDigit()).foregroundStyle(theme.primary)
            HStack(spacing: 3) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right").font(.system(size: 9, weight: .bold))
                Text(String(format: "%+.2f%%", q.changePercent)).font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(c)
        }
        .padding(10).frame(width: 118, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.card))
        .help(q.name)
    }
}

// MARK: - Desktop pet (off by default)
//
// One emoji layer walking along the bottom of the desktop. The walk is a single Core Animation
// animation, so the app does no per-frame work. It sits above the wallpaper and desktop icons but
// below app windows, never takes clicks, and goes away when switched off.

@MainActor
final class DeskPet {
    static let shared = DeskPet()
    private var panel: NSPanel?
    private(set) var sprite: CALayer?
    var isRunning: Bool { panel != nil }

    func setEnabled(_ on: Bool) {
        on ? start() : stop()
    }

    private func start() {
        guard panel == nil, let screen = NSScreen.screens.first else { return }
        let vis = screen.visibleFrame
        var frame = NSRect(x: vis.minX, y: vis.minY, width: vis.width, height: 46)
        if Env.isolated { frame.origin.x = -20000 }   // test instances never draw on the real desktop
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        p.contentView = host

        let layer = CALayer()
        let size: CGFloat = 34
        layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        layer.contentsScale = screen.backingScaleFactor
        layer.contents = Self.emojiImage("🐈", size: size, scale: screen.backingScaleFactor)
        layer.position = CGPoint(x: size, y: size / 2 + 4)
        host.layer?.addSublayer(layer)
        sprite = layer

        let oneWay = max(30, Double(vis.width) / 22)         // ~22 pt per second
        let a = CAKeyframeAnimation(keyPath: "position.x")
        a.values = [size, vis.width - size, size]
        a.keyTimes = [0, 0.5, 1]
        a.duration = oneWay * 2
        a.repeatCount = .infinity
        a.calculationMode = .linear
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "walk")

        let flip = CAKeyframeAnimation(keyPath: "transform.scale.x")
        flip.values = [1, -1]
        flip.keyTimes = [0, 0.5]
        flip.calculationMode = .discrete
        flip.duration = oneWay * 2
        flip.repeatCount = .infinity
        flip.isRemovedOnCompletion = false
        layer.add(flip, forKey: "flip")

        let bob = CABasicAnimation(keyPath: "position.y")
        bob.fromValue = size / 2 + 4
        bob.toValue = size / 2 + 8
        bob.duration = 0.45
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(bob, forKey: "bob")

        p.orderFrontRegardless()
        panel = p
    }

    private func stop() {
        sprite?.removeAllAnimations()
        panel?.orderOut(nil)
        panel = nil; sprite = nil
    }

    static func emojiImage(_ s: String, size: CGFloat, scale: CGFloat) -> CGImage? {
        let px = Int(size * scale)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size * scale * 0.82)])
        let sz = str.size()
        str.draw(at: NSPoint(x: (CGFloat(px) - sz.width) / 2, y: (CGFloat(px) - sz.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
