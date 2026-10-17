// Renders the Glance app icon (black squircle with a floating pill) into an .iconset.
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (px, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let r = NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    let bg = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(colors: [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.05, alpha: 1)])!.draw(in: bg, angle: -90)
    NSColor(white: 1, alpha: 0.08).setStroke(); bg.lineWidth = max(1, s * 0.004); bg.stroke()
    let pw = r.width * 0.56, ph = r.width * 0.16
    let pill = NSRect(x: r.midX - pw/2, y: r.maxY - r.height * 0.26 - ph/2, width: pw, height: ph)
    NSColor.black.setFill(); NSBezierPath(roundedRect: pill, xRadius: ph/2, yRadius: ph/2).fill()
    NSColor(white: 1, alpha: 0.12).setStroke(); let pp = NSBezierPath(roundedRect: pill, xRadius: ph/2, yRadius: ph/2); pp.lineWidth = max(0.5, s*0.003); pp.stroke()
    // tiny bars inside pill
    let bw = ph * 0.13
    for i in 0..<4 { let h = ph * [0.35, 0.6, 0.45, 0.25][i]; NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.6, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: pill.maxX - ph*0.5 - CGFloat(3-i)*bw*1.8, y: pill.midY - h/2, width: bw, height: h), xRadius: bw/2, yRadius: bw/2).fill() }
    let art = NSRect(x: pill.minX + ph*0.25, y: pill.midY - ph*0.3, width: ph*0.6, height: ph*0.6)
    NSGradient(colors: [NSColor.systemOrange, NSColor.systemPink])!.draw(in: NSBezierPath(roundedRect: art, xRadius: ph*0.14, yRadius: ph*0.14), angle: 45)
    // frosted card hint
    let card = NSRect(x: r.minX + r.width*0.14, y: r.minY + r.height*0.16, width: r.width*0.72, height: r.height*0.38)
    NSColor(white: 1, alpha: 0.10).setFill(); NSBezierPath(roundedRect: card, xRadius: r.width*0.07, yRadius: r.width*0.07).fill()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
