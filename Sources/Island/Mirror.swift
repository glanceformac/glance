import AppKit
import SwiftUI
@preconcurrency import AVFoundation
import Observation

/// Webcam mirror: live preview only. Frames are never recorded, saved or sent anywhere.
/// The only processing is an average-brightness check on a coarse grid, twice a second.
@Observable @MainActor
final class Mirror {
    static let shared = Mirror()

    enum State: Equatable { case off, starting, running, denied, unavailable, placeholder }
    private(set) var state: State = .off
    private(set) var hint: String?

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private var configured = false
    @ObservationIgnored private let queue = DispatchQueue(label: "island.mirror")
    @ObservationIgnored private lazy var sampler = BrightnessSampler { hint in
        Task { @MainActor in Mirror.shared.hint = hint }
    }

    func start() {
        guard state == .off || state == .denied || state == .unavailable else { return }
        if Env.noPermissions { state = .placeholder; hint = "Good light"; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: run()
        case .notDetermined:
            state = .starting
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor in
                    guard IslandModel.shared.page == .mirror, IslandModel.shared.expanded else { Mirror.shared.state = .off; return }
                    ok ? Mirror.shared.run() : (Mirror.shared.state = .denied)
                }
            }
        default: state = .denied
        }
    }

    private func run() {
        if !configured {
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else {
                state = .unavailable; return
            }
            session.beginConfiguration()
            session.sessionPreset = .medium
            if session.canAddInput(input) { session.addInput(input) }
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(sampler, queue: queue)
            if session.canAddOutput(out) { session.addOutput(out) }
            session.commitConfiguration()
            configured = true
        }
        state = .running
        let s = session
        queue.async { s.startRunning() }
    }

    /// Stops the camera immediately (the green camera light goes off).
    func stop() {
        guard state != .off else { return }
        state = .off
        hint = nil
        let s = session
        if s.isRunning { queue.async { s.stopRunning() } }
    }

    func openPrivacySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(u) }
    }
}

/// Average brightness on a coarse grid, at most twice a second. Nothing is kept.
final class BrightnessSampler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private var last = Date.distantPast
    private let report: @Sendable (String) -> Void
    init(report: @escaping @Sendable (String) -> Void) { self.report = report }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.5, let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        last = now
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px) else { return }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), row = CVPixelBufferGetBytesPerRow(px)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var left = 0.0, right = 0.0, nl = 0.0, nr = 0.0
        for gy in 0..<12 {
            let y = (gy * 2 + 1) * h / 24
            for gx in 0..<16 {
                let x = (gx * 2 + 1) * w / 32
                let o = y * row + x * 4
                let lum = 0.0722 * Double(p[o]) + 0.7152 * Double(p[o + 1]) + 0.2126 * Double(p[o + 2])
                if gx < 8 { left += lum; nl += 1 } else { right += lum; nr += 1 }
            }
        }
        let l = left / max(nl, 1), r = right / max(nr, 1), avg = (l + r) / 2
        let text: String
        if avg < 55 { text = "Too dark" }
        else if avg > 205 { text = "Too bright" }
        else if abs(l - r) > 45 { text = "Light from one side" }
        else { text = "Good light" }
        report(text)
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        v.layer = layer
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct MirrorView: View {
    let theme: Theme
    private let mirror = Mirror.shared
    private let circle = AppSettings.shared.prefs.mirrorCircle

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                switch mirror.state {
                case .running:
                    CameraPreview(session: mirror.session)
                        .scaleEffect(x: -1, y: 1) // mirror image
                case .placeholder:
                    ZStack {
                        LinearGradient(colors: [Color(white: 0.3), Color(white: 0.15)], startPoint: .top, endPoint: .bottom)
                        Image(systemName: "person.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.35))
                    }
                case .denied, .unavailable:
                    VStack(spacing: 6) {
                        Image(systemName: "video.slash").font(.system(size: 20)).foregroundStyle(theme.secondary)
                        Text(mirror.state == .denied ? "Camera access is off" : "No camera found")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.secondary).multilineTextAlignment(.center)
                    }
                default:
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 124, height: 124)
            .background(theme.card)
            .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 22, style: .continuous)))
            .overlay(alignment: .bottom) {
                if let h = mirror.hint {
                    Text(h).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 8).frame(height: 18)
                        .background(Capsule().fill(theme.accent.opacity(0.92)))
                        .padding(.bottom, circle ? 4 : 7)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: mirror.hint)

            VStack(alignment: .leading, spacing: 6) {
                Text("Mirror").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primary)
                Text("Preview only. Nothing is recorded, saved or sent. The camera turns off when you leave this page or the island closes.")
                    .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                if mirror.state == .denied {
                    Button("Open Camera Privacy Settings") { mirror.openPrivacySettings() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                if mirror.state == .placeholder {
                    Text("Test mode: camera not requested.").font(.system(size: 10)).foregroundStyle(theme.tertiary)
                }
            }
            .frame(maxWidth: 300, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .onAppear { mirror.start() }
        .onDisappear { mirror.stop() }
    }
}
