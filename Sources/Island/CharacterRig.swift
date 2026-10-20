import AppKit
import AVFoundation
import SwiftUI

/// Draws one character pose with Core Animation: the art (a still or a looping video), the
/// glow, and the small effects (z's, sparkles, the Shelf file, the meeting watch, shadow clones).
/// Everything is laid out in a 124 x 120 point box (the expanded island size) and scaled to the
/// view, so the island, the notch and the Touch Bar show the same pose and the same motion.
///
/// Battery: animations run in the render server (no per-frame app work) at up to 30 fps.
/// The rig freezes (layer speed 0, video paused) when its window is hidden or covered, when the
/// screens sleep, and when it leaves the window.
final class CharacterRigView: NSView {
    static let design = CGSize(width: 124, height: 120)
    static let rate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)

    private let root = CALayer()
    private let backing = CAGradientLayer()
    private let glowBelow = CAGradientLayer()
    private let glowAbove = CAGradientLayer()
    private let ent = CALayer()
    private let mot = CALayer()
    private let img = CALayer()
    private let videoBox = CALayer()
    private let videoMask = CAGradientLayer()
    private let videoFade = CAGradientLayer()
    private var playerLayer: AVPlayerLayer?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var videoURL: URL?
    private let fx = CALayer()
    private var zs: [CATextLayer] = []
    private var sparks: [CAShapeLayer] = []
    private let doc = CALayer()
    private let watch = CALayer()
    private let watchHand = CALayer()
    private let cloneHost = CALayer()
    private var cloneLayers: [CALayer] = []
    private let moreLabel = CATextLayer()

    /// Uses the pack's small Touch Bar stills when it has them.
    var compact = false
    /// Videos made on black only play on a dark backdrop (the black notch, the dark island).
    var darkBackdrop = true
    /// Paused from outside (screens asleep, island hidden).
    var externallyPaused = false { didSet { updateRunning() } }

    private var pack: CharacterPack?
    private var frameValue = CharacterFrame()
    private var contentKey = ""
    private var appliedSerial = -1
    private var running = false
    private var pausedTime: CFTimeInterval = 0
    private var occlusionObs: NSObjectProtocol?
    private static var aspects: [URL: CGFloat] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        root.bounds = CGRect(origin: .zero, size: Self.design)
        // The view is flipped, so AppKit already flips this layer tree (top-left origin, y down).
        layer?.addSublayer(root)

        backing.type = .radial
        backing.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        backing.locations = [0, 0.62, 1]
        backing.startPoint = CGPoint(x: 0.5, y: 0.5); backing.endPoint = CGPoint(x: 1, y: 1)
        backing.isHidden = true
        for g in [glowBelow, glowAbove] {
            g.type = .radial
            g.startPoint = CGPoint(x: 0.5, y: 0.5); g.endPoint = CGPoint(x: 1, y: 1)
            g.frame = CGRect(x: 2, y: -6, width: 120, height: 120)
            g.opacity = 0
        }
        // Screen blend over the video's black backdrop, like a soft aura glow.
        glowAbove.compositingFilter = "screenBlendMode"
        root.addSublayer(backing)
        root.addSublayer(glowBelow)

        for l in [ent, mot] {
            l.bounds = root.bounds
            l.anchorPoint = CGPoint(x: 0.5, y: 1)
            l.position = CGPoint(x: Self.design.width / 2, y: Self.design.height)
        }
        cloneHost.frame = root.bounds
        root.addSublayer(cloneHost)
        root.addSublayer(ent)
        ent.addSublayer(mot)
        img.contentsGravity = .resizeAspect
        mot.addSublayer(img)
        videoMask.startPoint = CGPoint(x: 0, y: 0.5); videoMask.endPoint = CGPoint(x: 1, y: 0.5)
        videoMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        videoMask.locations = [0, 0.16, 0.84, 1]
        videoFade.startPoint = CGPoint(x: 0.5, y: 0); videoFade.endPoint = CGPoint(x: 0.5, y: 1)
        videoFade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        videoFade.locations = [0, 0.14, 1]
        videoBox.mask = videoMask
        videoBox.isHidden = true
        mot.addSublayer(videoBox)
        root.addSublayer(glowAbove)

        fx.frame = root.bounds
        root.addSublayer(fx)
        buildFX()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let k = min(bounds.width / Self.design.width, bounds.height / Self.design.height)
        root.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
        // Bottom-centre of the box on the bottom-centre of the view.
        root.position = CGPoint(x: bounds.midX, y: bounds.maxY - Self.design.height * k / 2)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObs { NotificationCenter.default.removeObserver(o); occlusionObs = nil }
        if let w = window {
            occlusionObs = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                self?.updateRunning()
            }
            if let s = w.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor {
                for l in [img, doc, moreLabel] { l.contentsScale = s }
                zs.forEach { $0.contentsScale = s }
            }
        }
        updateRunning()
    }

    // MARK: Apply

    func apply(_ f: CharacterFrame, pack: CharacterPack?) {
        let packChanged = pack !== self.pack
        self.pack = pack
        frameValue = f
        guard let pack else { clear(); return }
        let media = pack.media(for: f.state, alt: f.alt)
        let compactSrc = compact ? pack.compactSource(for: f.state, alt: f.alt) : nil
        let useVideo = !f.stills && darkBackdrop && !compact && media?.video != nil
        let key = "\(pack.id)|\(f.state.rawValue)|\(f.alt)|\(useVideo)|\(compactSrc != nil)"
        let restart = f.serial != appliedSerial || packChanged
        let contentChanged = key != contentKey
        appliedSerial = f.serial
        contentKey = key

        CATransaction.begin(); CATransaction.setDisableActions(true)
        if contentChanged || restart {
            if !restart && contentChanged {
                // Same state, other art (the idle snack moment): a soft crossfade only.
                let t = CATransition(); t.type = .fade; t.duration = 0.38
                mot.add(t, forKey: "swap")
            }
            setContent(media: media, compact: compactSrc, video: useVideo)
        }
        CATransaction.commit()
        if restart { restartAnimations(entry: true) } else if contentChanged { restartAnimations(entry: false) }
        updateClones()
        updateRunning()
    }

    private func clear() {
        img.contents = nil
        stopVideo()
        videoBox.isHidden = true
        backing.isHidden = true
        [glowBelow, glowAbove].forEach { $0.opacity = 0; $0.removeAllAnimations() }
        cloneLayers.forEach { $0.removeFromSuperlayer() }; cloneLayers = []
        contentKey = ""
    }

    private func setContent(media: CharacterMedia?, compact src: CharacterMedia.Source?, video: Bool) {
        guard let pack else { return }
        if let src, let cg = pack.image(src) {
            // Touch Bar stills fill the box height.
            img.contents = cg
            let a = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
            var h = Self.design.height * 0.92, w = h * a
            if w > Self.design.width { w = Self.design.width; h = w / a }
            img.frame = CGRect(x: (Self.design.width - w) / 2, y: Self.design.height - h, width: w, height: h)
            img.isHidden = false
            videoBox.isHidden = true; backing.isHidden = true; stopVideo()
            return
        }
        guard let media else { img.contents = nil; return }
        if video, let url = media.video {
            img.isHidden = true
            img.contents = nil
            showVideo(url, height: media.videoHeight, bottom: media.videoBottom, onBlack: media.videoOnBlack)
        } else {
            stopVideo()
            videoBox.isHidden = true; backing.isHidden = true
            if let s = media.still, let cg = pack.image(s) {
                img.contents = cg
                let a = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
                var h = media.stillHeight, w = h * a
                if w > Self.design.width { w = Self.design.width; h = w / a }
                img.frame = CGRect(x: (Self.design.width - w) / 2, y: Self.design.height - media.stillBottom - h, width: w, height: h)
                img.isHidden = false
            } else {
                img.contents = nil
            }
        }
    }

    // MARK: Video

    private func showVideo(_ url: URL, height: CGFloat, bottom: CGFloat, onBlack: Bool) {
        let aspect = Self.aspects[url] ?? 1
        let w = min(Self.design.width, height * aspect)
        let box = CGRect(x: (Self.design.width - w) / 2, y: Self.design.height - bottom - height, width: w, height: height)
        videoBox.frame = box
        videoMask.frame = videoBox.bounds
        videoBox.isHidden = false
        backing.isHidden = !onBlack
        backing.frame = box.insetBy(dx: -14, dy: -10)
        if videoURL != url {
            stopVideo()
            let item = AVPlayerItem(url: url)
            let q = AVQueuePlayer()
            q.isMuted = true
            q.preventsDisplaySleepDuringVideoPlayback = false
            q.allowsExternalPlayback = false
            looper = AVPlayerLooper(player: q, templateItem: item)
            let pl = AVPlayerLayer(player: q)
            pl.videoGravity = .resizeAspect
            pl.backgroundColor = NSColor.black.cgColor
            pl.mask = videoFade
            videoBox.addSublayer(pl)
            playerLayer = pl
            player = q
            videoURL = url
            if Self.aspects[url] == nil {
                Task { @MainActor [weak self] in
                    let asset = AVURLAsset(url: url)
                    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                          let size = try? await track.load(.naturalSize), size.height > 0 else { return }
                    Self.aspects[url] = size.width / size.height
                    guard let self, self.videoURL == url else { return }
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    self.showVideo(url, height: height, bottom: bottom, onBlack: onBlack)
                    CATransaction.commit()
                }
            }
        }
        playerLayer?.frame = videoBox.bounds
        videoFade.frame = videoBox.bounds
        if running { player?.play() }
    }

    private func stopVideo() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        videoURL = nil
    }

    // MARK: Running / paused

    private func updateRunning() {
        let visible = window != nil && (window?.occlusionState.contains(.visible) ?? false) && !externallyPaused && pack != nil
        guard visible != running else { return }
        running = visible
        if visible {
            root.speed = 1
            root.timeOffset = 0
            root.beginTime = 0
            root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            player?.play()
        } else {
            pausedTime = root.convertTime(CACurrentMediaTime(), from: nil)
            root.speed = 0
            root.timeOffset = pausedTime
            player?.pause()
        }
    }

    // MARK: Animations

    private func now() -> CFTimeInterval { root.convertTime(CACurrentMediaTime(), from: nil) }

    private func kf(_ path: String, _ values: [Any], times: [NSNumber]? = nil, dur: CFTimeInterval, repeats: Bool = false,
                    delay: CFTimeInterval = 0, reverse: Bool = false, discrete: Bool = false,
                    timing: CAMediaTimingFunctionName = .easeInEaseOut, hold: Bool = false, on layer: CALayer) {
        let a = CAKeyframeAnimation(keyPath: path)
        a.values = values
        if let times { a.keyTimes = times }
        a.duration = dur
        a.repeatCount = repeats ? .infinity : 1
        a.autoreverses = reverse
        if discrete { a.calculationMode = .discrete }
        a.timingFunctions = Array(repeating: CAMediaTimingFunction(name: timing), count: max(values.count - 1, 1))
        a.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        a.fillMode = hold ? .both : .backwards
        a.isRemovedOnCompletion = !hold
        a.preferredFrameRateRange = Self.rate
        layer.add(a, forKey: path + (hold ? "-hold" : ""))
    }

    private func deg(_ d: Double) -> Double { d * .pi / 180 }

    private func restartAnimations(entry: Bool) {
        if entry { ent.removeAllAnimations() }
        for l in [mot, img, glowBelow, glowAbove, doc, watch, watchHand] { l.removeAllAnimations() }
        zs.forEach { $0.removeAllAnimations() }
        sparks.forEach { $0.removeAllAnimations() }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if entry { ent.opacity = 1 }
        img.shadowOpacity = 0
        glowBelow.frame = CGRect(x: 2, y: -6, width: 120, height: 120)
        for l in [glowBelow, glowAbove] { l.opacity = 0 }
        zs.forEach { $0.opacity = 0 }
        sparks.forEach { $0.opacity = 0 }
        doc.opacity = 0; watch.opacity = 0
        CATransaction.commit()

        let f = frameValue
        let still = f.stills
        let video = !videoBox.isHidden
        func setGlow(_ g: CAGradientLayer, _ c: NSColor) { g.colors = [c.cgColor, c.withAlphaComponent(0).cgColor] }

        // Entry (or the smoke puff for a movie).
        if !entry {
        } else if f.state == .movie {
            if still { ent.opacity = 0 } else {
                kf("opacity", [0, 1, 1, 1, 0], times: [0, 0.14, 0.3, 0.62, 1], dur: 1.5, timing: .easeOut, hold: true, on: ent)
                kf("transform.scale", [0.35, 1.08, 1, 1.04, 1.35], times: [0, 0.14, 0.3, 0.62, 1], dur: 1.5, timing: .easeOut, hold: true, on: ent)
                kf("transform.translation.y", [0, 0, 0, 0, -6], times: [0, 0.14, 0.3, 0.62, 1], dur: 1.5, hold: true, on: ent)
            }
        } else if !still {
            kf("opacity", [0, 1, 1], times: [0, 0.55, 1], dur: 0.6, timing: .easeOut, on: ent)
            kf("transform.translation.y", [12, -2, 0], times: [0, 0.55, 1], dur: 0.6, timing: .easeOut, on: ent)
            kf("transform.scale.x", [0.86, 1.03, 1], times: [0, 0.55, 1], dur: 0.6, timing: .easeOut, on: ent)
            kf("transform.scale.y", [0.9, 0.98, 1], times: [0, 0.55, 1], dur: 0.6, timing: .easeOut, on: ent)
        }

        switch f.state {
        case .approval:
            let orange = NSColor(red: 1, green: 0.5, blue: 0.16, alpha: 0.62)
            if video { setGlow(glowAbove, NSColor(red: 1, green: 0.47, blue: 0.12, alpha: 0.5)) } else { setGlow(glowBelow, orange) }
            let g = video ? glowAbove : glowBelow
            img.shadowColor = NSColor(red: 1, green: 0.55, blue: 0.2, alpha: 1).cgColor
            img.shadowOffset = .zero
            img.shadowRadius = 6
            img.shadowOpacity = video ? 0 : 0.9
            if still { g.opacity = 0.85 } else {
                kf("opacity", [0.45, 1, 0.45], dur: 1.3, repeats: true, hold: true, on: g)
                kf("transform.scale", [0.92, 1.06, 0.92], dur: 1.3, repeats: true, hold: true, on: g)
                if !video { kf("shadowRadius", [3, 10, 3], dur: 1.3, repeats: true, hold: true, on: img) }
                attention()
            }
        case .thinking:
            if !video {
                setGlow(glowBelow, NSColor(red: 0.35, green: 0.67, blue: 1, alpha: 0.55))
                glowBelow.frame = CGRect(x: -8, y: -20, width: 120, height: 120)
                img.shadowColor = NSColor(red: 0.43, green: 0.7, blue: 1, alpha: 1).cgColor
                img.shadowOffset = .zero; img.shadowRadius = 5; img.shadowOpacity = 0.9
                if still { glowBelow.opacity = 0.8 } else {
                    kf("opacity", [0.45, 1, 0.45], dur: 1.8, repeats: true, hold: true, on: glowBelow)
                    kf("shadowRadius", [2, 9, 2], dur: 1.8, repeats: true, hold: true, on: img)
                }
            }
            if !still { breathe(2.6) }
        case .finished, .shelf:
            if f.state == .finished {
                setGlow(glowBelow, NSColor(red: 0.4, green: 0.83, blue: 0.6, alpha: 0.35))
                if still { glowBelow.opacity = 0.7 } else { kf("opacity", [0, 1, 0.45, 0], dur: 1.6, delay: 0.1, on: glowBelow) }
            }
            if still {
                if f.state == .finished { sparks[0].opacity = 0.9; sparks[4].opacity = 0.9 } else { doc.opacity = 1 }
            } else if f.state == .finished {
                kf("transform.translation.y", [0, 2, -12, 0, 0, 0], times: [0, 0.14, 0.36, 0.56, 0.72, 1], dur: 1.15, delay: 0.15, on: mot)
                kf("transform.scale.x", [1, 1.06, 0.95, 1.06, 0.99, 1], times: [0, 0.14, 0.36, 0.56, 0.72, 1], dur: 1.15, delay: 0.15, on: mot)
                kf("transform.scale.y", [1, 0.92, 1.06, 0.94, 1.01, 1], times: [0, 0.14, 0.36, 0.56, 0.72, 1], dur: 1.15, delay: 0.15, on: mot)
                kf("transform.rotation.z", [0, 0, deg(-2), 0, 0, 0], times: [0, 0.14, 0.36, 0.56, 0.72, 1], dur: 1.15, delay: 0.15, on: mot)
                for (i, s) in sparks.enumerated() {
                    let d = 0.45 + [0, 0.05, 0.11, 0.17, 0.23][i]
                    kf("opacity", [0, 1, 0], times: [0, 0.4, 1], dur: 1, delay: d, on: s)
                    kf("transform.scale", [0, 1.15, 0.4], times: [0, 0.4, 1], dur: 1, delay: d, on: s)
                    kf("transform.rotation.z", [0, deg(45), deg(90)], times: [0, 0.4, 1], dur: 1, delay: d, on: s)
                }
            } else {
                kf("transform.translation.y", [0, 0, 3, -1, 0], times: [0, 0.4, 0.58, 0.78, 1], dur: 0.9, delay: 0.35, on: mot)
                kf("transform.scale.x", [1, 1, 1.05, 0.99, 1], times: [0, 0.4, 0.58, 0.78, 1], dur: 0.9, delay: 0.35, on: mot)
                kf("transform.scale.y", [1, 1, 0.93, 1.02, 1], times: [0, 0.4, 0.58, 0.78, 1], dur: 0.9, delay: 0.35, on: mot)
                doc.opacity = 1
                kf("opacity", [0, 1, 1, 1], times: [0, 0.3, 0.6, 1], dur: 0.9, timing: .easeOut, on: doc)
                kf("transform.translation.x", [6, 4, 0, 0], times: [0, 0.3, 0.6, 1], dur: 0.9, timing: .easeOut, on: doc)
                kf("transform.translation.y", [-70, -40, 3, 0], times: [0, 0.3, 0.6, 1], dur: 0.9, timing: .easeOut, on: doc)
                kf("transform.rotation.z", [deg(-24), deg(-12), deg(5), 0], times: [0, 0.3, 0.6, 1], dur: 0.9, timing: .easeOut, on: doc)
            }
        case .sleeping:
            if still { zs[0].opacity = 0.8 } else {
                kf("transform.scale.x", [1.015, 1.035, 1.015], dur: 5.2, repeats: true, on: mot)
                kf("transform.scale.y", [0.985, 1.02, 0.985], dur: 5.2, repeats: true, on: mot)
                for (i, z) in zs.enumerated() {
                    let d = Double(i) * 1.2
                    kf("opacity", [0, 0.9, 0], times: [0, 0.25, 1], dur: 3.6, repeats: true, delay: d, timing: .easeOut, on: z)
                    kf("transform.translation.x", [0, 9], dur: 3.6, repeats: true, delay: d, timing: .easeOut, on: z)
                    kf("transform.translation.y", [0, -16], dur: 3.6, repeats: true, delay: d, timing: .easeOut, on: z)
                    kf("transform.scale", [0.6, 1.15], dur: 3.6, repeats: true, delay: d, timing: .easeOut, on: z)
                }
            }
        case .music:
            if !still {
                kf("transform.translation.y", [0, -3, 0], times: [0, 0.45, 1], dur: 0.536, repeats: true, on: mot)
                kf("transform.scale.x", [1.02, 0.99, 1.02], times: [0, 0.45, 1], dur: 0.536, repeats: true, on: mot)
                kf("transform.scale.y", [0.98, 1.02, 0.98], times: [0, 0.45, 1], dur: 0.536, repeats: true, on: mot)
            }
        case .meeting:
            watch.opacity = 1
            if !still {
                breathe(3.8)
                kf("opacity", [0, 1], dur: 0.6, timing: .easeOut, on: watch)
                kf("transform.scale", [0.3, 1.1, 1], times: [0, 0.6, 1], dur: 0.6, timing: .easeOut, on: watch)
                kf("transform.rotation.z", [0, 0, deg(-12), deg(8), 0], times: [0, 0.7, 0.78, 0.88, 1], dur: 3.2, repeats: true, delay: 1, on: watch)
                kf("transform.rotation.z", (0...8).map { deg(Double($0) * 45) }, dur: 2, repeats: true, discrete: true, on: watchHand)
            }
        case .idle:
            if !still {
                if f.alt {
                    kf("transform.translation.y", [0, -1.5, 0.5, 0], times: [0, 0.3, 0.6, 1], dur: 1.6, repeats: true, on: mot)
                    kf("transform.scale.x", [1, 1.01, 1.015, 1], times: [0, 0.3, 0.6, 1], dur: 1.6, repeats: true, on: mot)
                    kf("transform.scale.y", [1, 1.025, 0.99, 1], times: [0, 0.3, 0.6, 1], dur: 1.6, repeats: true, on: mot)
                } else {
                    breathe(3.8)
                    kf("transform.rotation.z", [0, deg(-1.2), 0], dur: 7, repeats: true, on: mot)
                }
            }
        case .movie:
            break
        }
    }

    private func breathe(_ d: CFTimeInterval) {
        kf("transform.scale.x", [1, 1.012, 1], dur: d, repeats: true, on: mot)
        kf("transform.scale.y", [1, 1.028, 1], dur: d, repeats: true, on: mot)
    }

    private func attention() {
        let t: [NSNumber] = [0, 0.62, 0.72, 0.84, 1]
        kf("transform.translation.y", [0, 0, -4, 0, 0], times: t, dur: 2.4, repeats: true, delay: 0.5, on: mot)
        kf("transform.scale.x", [1, 1, 0.98, 1.03, 1], times: t, dur: 2.4, repeats: true, delay: 0.5, on: mot)
        kf("transform.scale.y", [1, 1, 1.03, 0.97, 1], times: t, dur: 2.4, repeats: true, delay: 0.5, on: mot)
    }

    // MARK: Effects

    private func buildFX() {
        let zSpec: [(CGFloat, CGFloat, CGFloat)] = [(74, 46, 13), (86, 36, 11), (96, 26, 9)]
        for (x, y, size) in zSpec {
            let t = CATextLayer()
            t.string = NSAttributedString(string: "z", attributes: [.font: NSFont.systemFont(ofSize: size, weight: .heavy),
                                                                     .foregroundColor: NSColor(red: 0.78, green: 0.81, blue: 1, alpha: 1)])
            t.frame = CGRect(x: x, y: y, width: size + 4, height: size + 4)
            t.contentsScale = 2
            t.shadowColor = NSColor(red: 0.55, green: 0.59, blue: 1, alpha: 1).cgColor
            t.shadowRadius = 4; t.shadowOpacity = 0.6; t.shadowOffset = .zero
            t.opacity = 0
            fx.addSublayer(t); zs.append(t)
        }
        let sSpec: [(CGFloat, CGFloat, CGFloat)] = [(12, 26, 12), (96, 18, 9), (104, 54, 8), (6, 64, 8), (56, 6, 10)]
        for (x, y, s) in sSpec {
            let l = CAShapeLayer()
            l.frame = CGRect(x: x, y: y, width: s, height: s)
            let p = CGMutablePath()
            let pts: [(CGFloat, CGFloat)] = [(0.5, 0), (0.61, 0.39), (1, 0.5), (0.61, 0.61), (0.5, 1), (0.39, 0.61), (0, 0.5), (0.39, 0.39)]
            for (i, q) in pts.enumerated() {
                let pt = CGPoint(x: q.0 * s, y: q.1 * s)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath()
            l.path = p
            l.fillColor = NSColor(red: 1, green: 0.886, blue: 0.48, alpha: 1).cgColor
            l.shadowColor = NSColor(red: 1, green: 0.86, blue: 0.43, alpha: 1).cgColor
            l.shadowRadius = 3; l.shadowOpacity = 0.9; l.shadowOffset = .zero
            l.opacity = 0
            fx.addSublayer(l); sparks.append(l)
        }
        // The file that lands on the Shelf.
        doc.frame = CGRect(x: 24, y: 62, width: 22, height: 28)
        doc.backgroundColor = NSColor.white.cgColor
        doc.cornerRadius = 4
        doc.shadowColor = NSColor.black.cgColor; doc.shadowOpacity = 0.5; doc.shadowRadius = 6; doc.shadowOffset = CGSize(width: 0, height: 4)
        let pdf = CATextLayer()
        pdf.string = NSAttributedString(string: "PDF", attributes: [.font: NSFont.systemFont(ofSize: 7, weight: .heavy),
                                                                     .foregroundColor: NSColor(red: 0.9, green: 0.33, blue: 0.29, alpha: 1)])
        pdf.alignmentMode = .center
        pdf.contentsScale = 2
        pdf.frame = CGRect(x: 0, y: 15, width: 22, height: 10)
        doc.addSublayer(pdf)
        doc.opacity = 0
        fx.addSublayer(doc)
        // The meeting watch.
        watch.frame = CGRect(x: 70, y: 32, width: 26, height: 26)
        watch.cornerRadius = 13
        watch.backgroundColor = NSColor(red: 0.086, green: 0.086, blue: 0.1, alpha: 1).cgColor
        watch.borderWidth = 2
        watch.borderColor = NSColor(red: 0.95, green: 0.77, blue: 0.43, alpha: 1).cgColor
        watch.shadowColor = NSColor(red: 0.95, green: 0.77, blue: 0.43, alpha: 1).cgColor
        watch.shadowOpacity = 0.45; watch.shadowRadius = 6; watch.shadowOffset = .zero
        let gold = NSColor(red: 0.95, green: 0.77, blue: 0.43, alpha: 1).cgColor
        watchHand.bounds = CGRect(x: 0, y: 0, width: 2, height: 9)
        watchHand.anchorPoint = CGPoint(x: 0.5, y: 1)
        watchHand.position = CGPoint(x: 13, y: 13)
        watchHand.backgroundColor = gold; watchHand.cornerRadius = 1
        let hour = CALayer()
        hour.bounds = CGRect(x: 0, y: 0, width: 2, height: 6)
        hour.anchorPoint = CGPoint(x: 0.5, y: 1)
        hour.position = CGPoint(x: 13, y: 13)
        hour.backgroundColor = gold; hour.cornerRadius = 1
        hour.setAffineTransform(CGAffineTransform(rotationAngle: .pi * 150 / 180))
        watch.addSublayer(hour); watch.addSublayer(watchHand)
        watch.opacity = 0
        fx.addSublayer(watch)
        moreLabel.alignmentMode = .center
        moreLabel.contentsScale = 2
        moreLabel.frame = CGRect(x: 92, y: 2, width: 30, height: 14)
        moreLabel.opacity = 0
        fx.addSublayer(moreLabel)
    }

    // MARK: Shadow clones (running Claude Code subagents)
    // TODO(phase 2): this is a first, simple version (translucent copies behind the main pose, +N).
    // The full Shadow Clones design (one cell per agent, per-clone states, Touch Bar runners) is not built yet.

    private static let cloneSlots: [(x: CGFloat, y: CGFloat, s: CGFloat)] = [(-34, 0, 0.78), (34, 0, 0.78), (-50, -6, 0.62), (50, -6, 0.62), (0, -14, 0.58)]

    private func updateClones() {
        let want = frameValue.gone || frameValue.state == .movie ? 0 : min(frameValue.clones, Self.cloneSlots.count)
        let src = img.contents
        CATransaction.begin(); CATransaction.setDisableActions(true)
        while cloneLayers.count > want {
            let l = cloneLayers.removeLast()
            // Poof: a quick puff outwards, then gone.
            let g = CAAnimationGroup()
            let s = CABasicAnimation(keyPath: "transform.scale"); s.toValue = 1.4
            let o = CABasicAnimation(keyPath: "opacity"); o.toValue = 0
            g.animations = [s, o]; g.duration = 0.45; g.fillMode = .forwards; g.isRemovedOnCompletion = false
            l.add(g, forKey: "poof")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { l.removeFromSuperlayer() }
        }
        while cloneLayers.count < want {
            let slot = Self.cloneSlots[cloneLayers.count]
            let l = CALayer()
            l.contentsGravity = .resizeAspect
            l.opacity = 0.42
            l.shadowColor = NSColor.white.cgColor; l.shadowOpacity = 0.5; l.shadowRadius = 2; l.shadowOffset = .zero
            cloneHost.addSublayer(l)
            cloneLayers.append(l)
            let g = CAAnimationGroup()
            let s = CABasicAnimation(keyPath: "transform.scale"); s.fromValue = 0.4
            let o = CABasicAnimation(keyPath: "opacity"); o.fromValue = 0
            g.animations = [s, o]; g.duration = 0.4
            l.add(g, forKey: "in")
            _ = slot
        }
        // Clones copy the current still (or the idle art while a video plays).
        let idleArt: CGImage? = pack?.media["idle"]?.still.flatMap { pack?.image($0) }
        let still: Any? = src ?? idleArt
        for (i, l) in cloneLayers.enumerated() {
            let slot = Self.cloneSlots[i]
            let base = img.isHidden ? CGRect(x: 32, y: 10, width: 60, height: 110) : img.frame
            let w = base.width * slot.s, h = base.height * slot.s
            l.frame = CGRect(x: base.midX + slot.x - w / 2, y: Self.design.height - h + slot.y, width: w, height: h)
            l.contents = still
        }
        let extra = frameValue.clones - want
        moreLabel.opacity = extra > 0 && want > 0 ? 1 : 0
        moreLabel.string = NSAttributedString(string: "+\(max(extra, 0))", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold),
                                                                                         .foregroundColor: NSColor(red: 0.43, green: 0.7, blue: 1, alpha: 1)])
        CATransaction.commit()
    }
}

extension CharacterRigView {
    /// Debug / self test: one pose as stills, rendered offscreen at 2x on grey.
    static func snapshot(_ state: CharacterState, pack: CharacterPack, alt: Bool = false) -> CGImage? {
        let v = CharacterRigView(frame: NSRect(x: 0, y: 0, width: 124, height: 120))
        v.apply(CharacterFrame(state: state, alt: alt, serial: 1, stills: true), pack: pack)
        v.layoutSubtreeIfNeeded()
        guard let layer = v.layer, let ctx = CGContext(data: nil, width: 248, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor(white: 0.3, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 248, height: 240))
        ctx.scaleBy(x: 2, y: 2)
        ctx.translateBy(x: 0, y: 120); ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        return ctx.makeImage()
    }
}

// MARK: - SwiftUI

/// The character rig in SwiftUI. Pass `frame` and `pack` for previews; by default it follows
/// the live engine.
struct CharacterRig: NSViewRepresentable {
    var frame: CharacterFrame? = nil
    var pack: CharacterPack? = nil
    var compact = false
    var darkBackdrop = true

    func makeNSView(context: Context) -> CharacterRigView {
        let v = CharacterRigView(frame: .zero)
        v.compact = compact
        return v
    }

    func updateNSView(_ v: CharacterRigView, context: Context) {
        let engine = CharacterEngine.shared
        v.compact = compact
        v.darkBackdrop = darkBackdrop
        v.externallyPaused = engine.screensAsleep || AppSettings.shared.prefs.islandHidden && frame == nil
        v.apply(frame ?? engine.frame, pack: frame == nil ? engine.pack : pack)
    }
}

/// The character inside the closed pill / notch: the same rig, scaled to the pill height.
struct CharacterPillSlot: View {
    let theme: Theme
    var body: some View {
        let h = max(20, IslandModel.shared.closedSize.height - 2)
        CharacterRig(darkBackdrop: theme.dark)
            .frame(width: min(36, h * CharacterRigView.design.width / CharacterRigView.design.height), height: h)
            .padding(.leading, 8)
            .padding(.top, 1)
            .transition(.opacity.combined(with: .offset(y: -6)))
    }
}

/// A tiny status mark on the right of the closed pill (only when nothing else is shown there).
struct CharacterPillIndicator: View {
    var body: some View {
        let f = CharacterEngine.shared.frame
        HStack(spacing: 5) {
            switch f.state {
            case .thinking:
                Circle().fill(Color(red: 0.43, green: 0.7, blue: 1)).frame(width: 7, height: 7).shadow(color: Color(red: 0.43, green: 0.7, blue: 1), radius: 4)
            case .approval:
                Circle().fill(Color(red: 0.94, green: 0.54, blue: 0.24)).frame(width: 9, height: 9).shadow(color: .orange, radius: 4)
            case .finished:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color(red: 0.2, green: 0.78, blue: 0.35))
            case .shelf:
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 11)
            case .meeting:
                let mins = CalendarService.shared.nextStart.map { max(1, Int(($0.timeIntervalSinceNow / 60).rounded(.up))) } ?? 5
                Text("\(mins)m").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color(red: 0.95, green: 0.77, blue: 0.43))
            default:
                EmptyView()
            }
            if f.clones > 0 {
                Text("x\(f.clones)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(Color(red: 0.43, green: 0.7, blue: 1))
            }
        }
        .animation(.easeOut(duration: 0.25), value: f.state)
    }
}
