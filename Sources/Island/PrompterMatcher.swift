import Foundation

// MARK: feat/prompter: pure logic (Foundation only, so Scripts/prompter-match-test.swift can compile it alone)

/// Maps recognised speech to a word position in the script.
///
/// Each update takes the last few recognised words and runs a small local alignment
/// (Smith-Waterman) against a window of the script around the current position. Short,
/// common words count for less, near-misses ("handover" / "handovers") count for most of a
/// word, and big moves (skipping ahead, or going back to repeat a sentence) need a longer
/// run of matching words than small steps forward. Cost is a few thousand comparisons per
/// update, a handful of times a second.
struct ScriptMatcher {
    let words: [String]
    /// Index of the script word most recently spoken (-1 before anything is matched).
    private(set) var position = -1
    /// Last tail that was matched (partial results repeat; nothing to do if unchanged).
    private var lastTail: [String] = []

    var tailLength = 8
    var backWindow = 400
    var forwardWindow = 260
    /// Weighted score needed for a small step forward, a long jump ahead, or a step back.
    var nearThreshold = 1.6
    var jumpThreshold = 2.6
    var backThreshold = 2.6
    /// Words ahead of the current position that still count as "near".
    var nearAhead = 24

    init(words: [String]) { self.words = words }
    init(script: String) { words = Self.tokens(script) }

    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "/" }).map { norm(String($0)) }.filter { !$0.isEmpty }
    }

    static func norm(_ w: String) -> String {
        w.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    static let stopWords: Set<String> = ["a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "is", "it",
                                         "we", "i", "you", "that", "this", "be", "are", "was", "with", "as", "so", "by", "our", "my"]

    static func weight(_ w: String) -> Double {
        if stopWords.contains(w) { return 0.45 }
        return w.count <= 3 ? 0.75 : 1.0
    }

    /// 1 = same word, 0.7 = close (one or two edits on a longer word, or a shared stem), 0 = different.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        guard a.count >= 4, b.count >= 4 else { return 0 }
        let pa = a.prefix(5), pb = b.prefix(5)
        if a.count >= 5, b.count >= 5, pa == pb { return 0.7 }
        let d = editDistance(Array(a), Array(b), limit: 2)
        let longer = max(a.count, b.count)
        return d <= (longer >= 7 ? 2 : 1) ? 0.7 : 0
    }

    static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Jump the position (manual scrubbing, restart): matching continues from here.
    mutating func reset(to word: Int) { position = max(-1, min(words.count - 1, word)); lastTail = [] }

    /// Feed the recogniser's current hypothesis (all words of this utterance, latest last).
    /// Returns the new position when it moved.
    @discardableResult
    mutating func hear(_ hypothesis: [String]) -> Int? {
        let tail = Array(hypothesis.suffix(tailLength).map(Self.norm).filter { !$0.isEmpty })
        guard tail.count >= 2, !words.isEmpty, tail != lastTail else { return nil }
        lastTail = tail
        let here = max(position, 0)
        let lo = max(0, here - backWindow), hi = min(words.count - 1, here + forwardWindow)
        guard lo <= hi else { return nil }
        let seg = Array(words[lo...hi])
        let t = tail.count, n = seg.count
        let gap = 0.5, mismatch = 0.45
        // H[i][j]: best local alignment ending at tail[i-1], seg[j-1].
        var prev = [Double](repeating: 0, count: n + 1), cur = prev
        var endScores = [Double](repeating: 0, count: n)   // best alignment ending at seg[j] with one of the last 2 tail words
        for i in 1...t {
            cur[0] = 0
            let w = tail[i - 1], wt = Self.weight(w)
            for j in 1...n {
                let sim = Self.similarity(w, seg[j - 1])
                let diag = prev[j - 1] + (sim > 0 ? sim * wt : -mismatch)
                cur[j] = max(0, diag, prev[j] - gap, cur[j - 1] - gap)
                // An alignment may only end on a real match of one of the newest words
                // (the very last word may still be misheard, so the one before also counts).
                if i >= t - 1, sim > 0, diag > 0, diag >= cur[j] - 0.0001 {
                    endScores[j - 1] = max(endScores[j - 1], diag - (i == t ? 0 : 0.3))
                }
            }
            swap(&prev, &cur)
        }
        var best = -1, bestValue = -Double.infinity, bestScore = 0.0
        for j in 0..<n where endScores[j] > 0 {
            let idx = lo + j, delta = idx - position
            let needed: Double
            if delta >= -1 && delta <= nearAhead { needed = nearThreshold }
            else if delta > nearAhead { needed = jumpThreshold }
            else { needed = backThreshold }
            guard endScores[j] >= needed else { continue }
            // Prefer the nearest good match just ahead; going back costs a little more.
            let dist = delta >= 0 ? Double(delta) * 0.006 : Double(-delta) * 0.012
            let v = endScores[j] - dist
            if v > bestValue { bestValue = v; best = idx; bestScore = endScores[j] }
        }
        _ = bestScore
        guard best >= 0, best != position else { return nil }
        position = best
        return best
    }
}

/// Speaking / silent decision from microphone level, with hysteresis: a higher level to start
/// than to keep going, a short attack so a cough doesn't start scrolling, and a longer release
/// so the gaps between words and short breaths don't stop it. The noise floor adapts slowly.
struct VoiceGate {
    var onRatio: Float = 3.2, offRatio: Float = 1.8
    var minOn: Float = 0.012, minOff: Float = 0.006
    var attack = 0.12, release = 0.9
    private(set) var speaking = false
    private(set) var floor: Float = 0.003
    private var above = 0.0, below = 0.0

    init() {}

    /// Feed one buffer's RMS level and its duration. Returns the new state when it changes.
    mutating func feed(rms: Float, dt: Double) -> Bool? {
        // Noise floor: falls quickly to quiet levels, rises very slowly (so speech doesn't lift it).
        floor = rms < floor ? floor * 0.9 + rms * 0.1 : floor + (rms - floor) * 0.002
        floor = max(0.0005, min(floor, 0.05))
        let on = max(minOn, floor * onRatio), off = max(minOff, floor * offRatio)
        if speaking {
            if rms < off { below += dt } else { below = 0 }
            if below >= release { speaking = false; below = 0; above = 0; return false }
        } else {
            if rms > on { above += dt } else { above = max(0, above - dt) }
            if above >= attack { speaking = true; above = 0; below = 0; return true }
        }
        return nil
    }
}
