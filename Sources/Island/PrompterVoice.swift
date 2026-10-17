import AVFoundation
import Accelerate
import Speech

// MARK: feat/prompter: voice follow. Nothing is recorded and nothing leaves the Mac.

/// Microphone level (basic) and on-device speech recognition (smart).
///
/// The level gate runs on the audio thread and calls back only when speaking starts or stops,
/// so the main thread does no per-buffer work. Smart mode hands each partial result (a few a
/// second) to `onWords`. Permissions are asked for only here, the first time voice follow runs.
final class PrompterVoiceEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let wantSmart: Bool
    private let lock = NSLock()
    private var gate = VoiceGate()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private var stopped = false
    private var contextual: [String]

    var onSpeaking: ((Bool) -> Void)?
    var onWords: (([String]) -> Void)?
    /// (status text, smart recognition really running)
    var onStatus: ((String, Bool) -> Void)?

    init(smart: Bool, contextualStrings: [String]) { wantSmart = smart; contextual = contextualStrings }

    // MARK: Permissions (first use only; macOS shows each prompt once)

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: afterMic()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { ok ? self.afterMic() : self.onStatus?("Microphone access is off", false) }
            }
        default: onStatus?("Microphone access is off (System Settings > Privacy & Security > Microphone)", false)
        }
    }

    private func afterMic() {
        guard !stopped else { return }
        guard wantSmart else { run(smart: false); return }
        let go: (SFSpeechRecognizerAuthorizationStatus) -> Void = { st in
            if st == .authorized, self.recognizer?.supportsOnDeviceRecognition == true { self.run(smart: true) }
            else {
                self.onStatus?(st == .authorized ? "On-device recognition is not available for this language; following your voice level"
                                                 : "Speech Recognition is off; following your voice level", false)
                self.run(smart: false)
            }
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: SFSpeechRecognizer.requestAuthorization { st in DispatchQueue.main.async { go(st) } }
        case let st: go(st)
        }
    }

    // MARK: Audio

    private func run(smart: Bool) {
        guard !stopped else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { onStatus?("No microphone found", false); return }
        if smart { startRecognition() }
        onStatus?(smart ? "Following your words (on this Mac)" : "Scrolling while you speak", smart)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, _ in
            self?.process(buf)
        }
        engine.prepare()
        do { try engine.start() } catch { onStatus?("Could not start the microphone", false) }
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        lock.lock(); let req = request; lock.unlock()
        req?.append(buf)
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(ch, 1, &rms, vDSP_Length(buf.frameLength))
        let dt = Double(buf.frameLength) / buf.format.sampleRate
        if let change = gate.feed(rms: rms, dt: dt) { onSpeaking?(change) }
    }

    private func startRecognition() {
        guard let recognizer, !stopped else { return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.requiresOnDeviceRecognition = true      // never sent to Apple's servers
        r.shouldReportPartialResults = true
        r.taskHint = .dictation
        r.contextualStrings = contextual
        lock.lock(); request = r; lock.unlock()
        task = recognizer.recognitionTask(with: r) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.onWords?(result.bestTranscription.segments.map(\.substring))
                DispatchQueue.main.async { self.recognitionFailures = 0 }
            }
            // A task ends after a long pause or about a minute of audio: start a fresh one.
            // Errors back off (0.5 s, 1 s, 2 s ... up to 30 s) and give up after a few in a row,
            // so a missing or disabled recogniser (Siri & Dictation off) never spins.
            if error != nil || result?.isFinal == true {
                let failed = error != nil && result == nil
                DispatchQueue.main.async {
                    guard !self.stopped else { return }
                    self.lock.lock(); self.request?.endAudio(); self.request = nil; self.lock.unlock()
                    if failed { self.recognitionFailures += 1 } else { self.recognitionFailures = 0 }
                    if self.recognitionFailures > Self.maxRecognitionFailures {
                        self.onStatus?("Voice recognition is unavailable. Check Siri & Dictation in System Settings.", false)
                        return
                    }
                    let delay = failed ? min(0.5 * pow(2, Double(self.recognitionFailures - 1)), 30) : 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.startRecognition() }
                }
            }
        }
    }

    /// Consecutive recognition errors without any words heard (main queue only).
    private var recognitionFailures = 0
    private static let maxRecognitionFailures = 6

    func stop() {
        stopped = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); request?.endAudio(); request = nil; lock.unlock()
        task?.cancel(); task = nil
    }
}

/// Runs ScriptMatcher off the main thread; the result comes back on the main thread.
final class PrompterMatchWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.glanceformac.glance.prompter.match", qos: .userInitiated)
    private var matcher: ScriptMatcher

    init(words: [String]) { matcher = ScriptMatcher(words: words) }

    func hear(_ words: [String], done: @escaping @MainActor (Int?) -> Void) {
        queue.async {
            let moved = self.matcher.hear(words)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(moved) } }
        }
    }

    func reset(to word: Int) { queue.async { self.matcher.reset(to: word) } }
}
