// Test harness for the Prompter's smart voice follow (no microphone, no permissions).
// Feeds simulated speech-recogniser output (growing partial results, mishearings, skips,
// repeats, ad-libs, recogniser restarts) into ScriptMatcher, and synthetic levels into VoiceGate.
//
//   swiftc -O Sources/Glance/PrompterMatcher.swift Scripts/prompter-match-test.swift -o /tmp/prompter-match-test && /tmp/prompter-match-test
//
// (Compiled as two files, so this one has no top-level code: entry point is @main below.)
import Foundation

@main
struct PrompterMatchTest {
    static let script = """
    Good morning everyone, and thank you for joining today's review.
    We have three things to cover: the shift handover tool, the pilot results, and next steps.
    First, the handover tool. Nurses told us that the morning handover takes far too long, and important details get lost between shifts.
    So we built a simple summary that is ready before the shift starts.
    Second, the pilot results. Over four weeks, handover time dropped and fewer tasks were missed.
    Ward managers said the summary was clear, and the night team asked to keep using it.
    Finally, next steps. We would like to extend the pilot to two more wards this winter.
    Thank you for listening. I am happy to take any questions now.
    """
    static var sentences: [[String]] {
        script.split(separator: "\n").map { ScriptMatcher.tokens(String($0)) }
    }
    /// Index in the whole script of word w of sentence s.
    static func idx(_ s: Int, _ w: Int) -> Int { sentences[..<s].reduce(0) { $0 + $1.count } + w }

    nonisolated(unsafe) static var passed = 0, failed = 0
    static func check(_ name: String, _ ok: Bool, _ detail: String) {
        if ok { passed += 1; print("PASS  \(name)  (\(detail))") } else { failed += 1; print("FAIL  \(name)  (\(detail))") }
    }

    /// Speak words one at a time, like partial results: each update is the whole utterance so far.
    /// Every 3rd update the recogniser first reports a wrong guess for the newest word, then fixes it.
    static func speak(_ m: inout ScriptMatcher, _ utterance: inout [String], _ ws: [String], wobble: Bool = true) {
        for (k, w) in ws.enumerated() {
            if wobble && k % 3 == 2 { m.hear(utterance + ["uh"]) }
            utterance.append(w)
            m.hear(utterance)
        }
    }

    static func main() {
        let all = ScriptMatcher.tokens(script)
        print("Script: \(all.count) words, \(sentences.count) sentences\n")

        // 1. Straight read, word by word: position follows within one word at every sentence end.
        do {
            var m = ScriptMatcher(words: all), u: [String] = []
            var worst = 0
            for s in 0..<sentences.count {
                speak(&m, &u, sentences[s])
                worst = max(worst, abs(m.position - idx(s, sentences[s].count - 1)))
            }
            check("straight read", worst <= 1, "worst error at sentence ends = \(worst) words, final position \(m.position)/\(all.count - 1)")
        }

        // 2. Mishearings: near-misses and a few wrong words still track.
        do {
            var m = ScriptMatcher(words: all), u: [String] = []
            speak(&m, &u, sentences[0]); speak(&m, &u, sentences[1])
            var s2 = sentences[2]
            s2[4] = "nurse"; s2[8] = "mourning"; s2[9] = "hand"; s2[15] = "importance"; s2[17] = "lots"
            speak(&m, &u, s2)
            let target = idx(2, s2.count - 1)
            check("mishearings", abs(m.position - target) <= 1, "position \(m.position), expected \(target)")
        }

        // 3. Skip ahead: read sentence 0-1, jump straight to sentence 4.
        do {
            var m = ScriptMatcher(words: all), u: [String] = []
            speak(&m, &u, sentences[0]); speak(&m, &u, sentences[1])
            let before = m.position
            var firstIn: Int?
            for k in 0..<sentences[4].count {
                speak(&m, &u, [sentences[4][k]], wobble: false)
                if firstIn == nil, m.position >= idx(4, 0) { firstIn = k + 1 }
            }
            let target = idx(4, sentences[4].count - 1)
            check("skip ahead (2 sentences)", abs(m.position - target) <= 1 && (firstIn ?? 99) <= 4,
                  "from \(before) to \(m.position) (expected \(target)), caught up after \(firstIn.map(String.init) ?? "never") words")
        }

        // 4. Repeat: read sentences 0-3, then say sentence 3 again from the start.
        do {
            var m = ScriptMatcher(words: all), u: [String] = []
            for s in 0...3 { speak(&m, &u, sentences[s]) }
            let before = m.position
            var backAfter: Int?
            for k in 0..<sentences[3].count {
                speak(&m, &u, [sentences[3][k]], wobble: false)
                if backAfter == nil, m.position < idx(3, sentences[3].count - 2) { backAfter = k + 1 }
            }
            let target = idx(3, sentences[3].count - 1)
            check("repeat a sentence", abs(m.position - target) <= 1 && (backAfter ?? 99) <= 5,
                  "went back from \(before) after \(backAfter.map(String.init) ?? "never") words, ended at \(m.position) (expected \(target))")
            // ...and carries on forward normally.
            speak(&m, &u, sentences[4])
            check("forward after repeat", abs(m.position - idx(4, sentences[4].count - 1)) <= 1, "position \(m.position)")
        }

        // 5. Repeat of a short phrase only ("the pilot results") must NOT jump back on its own.
        do {
            var m = ScriptMatcher(words: all), u: [String] = []
            for s in 0...4 { speak(&m, &u, sentences[s]) }
            let before = m.position
            speak(&m, &u, ["um", "so", "yes"], wobble: false)
            check("ad-lib does not move", m.position == before, "before \(before), after \(m.position)")
            speak(&m, &u, ["and", "the", "of", "to"], wobble: false)
            check("stop words alone do not move", m.position == before, "position \(m.position)")
        }

        // 6. Recogniser restarts (new task: hypothesis starts empty) and reading continues.
        do {
            var m = ScriptMatcher(words: all), u: [String] = []
            for s in 0...2 { speak(&m, &u, sentences[s]) }
            u = []                                           // new recognition task
            speak(&m, &u, sentences[3])
            check("recogniser restart", abs(m.position - idx(3, sentences[3].count - 1)) <= 1, "position \(m.position)")
        }

        // 7. Skip backwards a long way (go back to the start) needs a clear run of words.
        do {
            var m = ScriptMatcher(words: all), u: [String] = []
            for s in 0...5 { speak(&m, &u, sentences[s]) }
            speak(&m, &u, Array(sentences[1].prefix(6)), wobble: false)
            check("jump back to sentence 2", abs(m.position - idx(1, 5)) <= 1, "position \(m.position), expected \(idx(1, 5))")
        }

        // 8. Same sentence twice in a script: the copy just ahead wins, not the one far away.
        do {
            let s = "Thank you all for coming. " + Array(repeating: "Here is some filler text about the weather and the trains today.", count: 3).joined(separator: " ")
                + " Thank you all for coming."
            let w = ScriptMatcher.tokens(s)
            var m = ScriptMatcher(words: w), u: [String] = []
            speak(&m, &u, Array(w.prefix(5)))
            check("duplicate sentence: nearer copy", m.position == 4, "position \(m.position) (first copy ends at 4, second at \(w.count - 1))")
        }

        // 9. Long script (2,000 words): matching cost per update.
        do {
            let long = Array(repeating: script, count: 13).joined(separator: "\n")
            var m = ScriptMatcher(script: long), u: [String] = []
            let ws = ScriptMatcher.tokens(long)
            let t0 = Date()
            var updates = 0
            for w in ws.prefix(600) { u.append(w); if u.count > 40 { u.removeFirst(20) }; m.hear(u); updates += 1 }
            let per = Date().timeIntervalSince(t0) / Double(updates) * 1000
            check("cost per update (\(ws.count)-word script)", per < 2.0, String(format: "%.3f ms per update, final position %d/599 region", per, m.position))
        }

        // VoiceGate: hysteresis with synthetic levels (21 ms buffers).
        do {
            var g = VoiceGate()
            let dt = 0.021
            var log: [String] = []
            func run(_ rms: Float, _ seconds: Double, _ label: String) {
                for _ in 0..<Int(seconds / dt) { if let s = g.feed(rms: rms, dt: dt) { log.append("\(label):\(s ? "on" : "off")") } }
            }
            run(0.002, 2, "room")                       // quiet room
            run(0.08, 0.05, "click")                    // a 50 ms click: too short to start
            run(0.002, 1, "room2")
            for i in 0..<6 { run(0.05, 0.35, "word\(i)"); run(0.004, 0.25, "gap\(i)") }   // speech with short gaps
            run(0.002, 1.5, "silence")                 // a real pause
            let starts = log.filter { $0.hasSuffix(":on") }.count, stops = log.filter { $0.hasSuffix(":off") }.count
            check("voice gate: click ignored", !log.contains { $0.hasPrefix("click") || $0.hasPrefix("room2") }, log.joined(separator: " "))
            check("voice gate: one start, one stop (gaps between words kept)", starts == 1 && stops == 1 && log.last?.hasPrefix("silence") == true, log.joined(separator: " "))
            // Noisy room: floor adapts, so steady fan noise does not count as speech.
            var g2 = VoiceGate(); var noisyStarts = 0
            for _ in 0..<Int(10 / dt) { if g2.feed(rms: 0.011, dt: dt) == true { noisyStarts += 1 } }
            check("voice gate: steady background noise", noisyStarts == 0, "starts \(noisyStarts), floor \(String(format: "%.4f", g2.floor))")
        }

        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
