import Foundation

/// One word as it appears on screen, in **clip-relative** time (seconds from the
/// start of the cut clip, not the source video).
struct CaptionWord: Sendable, Equatable, Codable {
    let text: String
    let start: Double
    let end: Double
}

/// A short group of words shown together as one on-screen caption line.
/// `start`/`end` span the whole line; each word keeps its own timing so the
/// renderer can highlight the currently-spoken word.
struct CaptionLine: Sendable, Equatable, Codable {
    let words: [CaptionWord]
    let start: Double
    let end: Double

    var text: String { words.map(\.text).joined(separator: " ") }
}

/// The full set of caption lines for one clip, ready to render.
///
/// Built **once per clip** (on `ShortClip`) and handed to BOTH the live preview
/// and the export pass, so what you see can never drift from what you download.
/// All value types → automatically `Sendable`, so it crosses the `nonisolated`
/// render boundary the same way `CaptionWord` does.
struct CaptionScript: Sendable, Equatable, Codable {
    let lines: [CaptionLine]

    var isEmpty: Bool { lines.isEmpty }

    /// Builds a clip-relative caption script from absolute-timed word stamps.
    ///
    /// - Parameters:
    ///   - words:     word stamps in SOURCE-video time (absolute seconds).
    ///   - clipStart: the cut clip's start in source time.
    ///   - clipEnd:   the cut clip's end in source time.
    ///   - maxWords:  soft cap on words per line.
    ///   - maxChars:  soft cap on rendered characters per line.
    ///   - lineBreakGap: a silence longer than this (seconds) forces a new line.
    ///
    /// Words overlapping the clip are kept, trimmed, and rebased so the clip
    /// starts at t=0 — the grouping step below only ever sees clean,
    /// clip-relative words.
    static func build(
        words: [WordStamp],
        clipStart: Double,
        clipEnd: Double,
        maxWords: Int = 3,
        maxChars: Int = 24,
        lineBreakGap: Double = 0.6
    ) -> CaptionScript {
        let span = max(0, clipEnd - clipStart)
        let rebased: [CaptionWord] = words
            .filter { $0.end > clipStart && $0.start < clipEnd }
            .map { w in
                CaptionWord(
                    text: w.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    start: min(max(w.start - clipStart, 0), span),
                    end: min(max(w.end - clipStart, 0), span))
            }
            .filter { !$0.text.isEmpty }

        return CaptionScript(lines: groupIntoLines(
            rebased, maxWords: maxWords, maxChars: maxChars, lineBreakGap: lineBreakGap))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // YOUR CALL #1 — Caption line-grouping heuristic
    //
    // This function decides how a flat stream of spoken words becomes the short,
    // punchy on-screen lines that define the viral-caption look. It's ~8 lines of
    // genuinely consequential logic, so it's yours to shape (Learning mode).
    //
    // The inputs are already clean: `words` are clip-relative, trimmed, non-empty,
    // in order. You return `[CaptionLine]` where each line's `start` is its first
    // word's `start` and `end` is its last word's `end`.
    //
    // Levers to weigh (mix freely):
    //   • maxWords  — hard-ish cap; ≤3 reads fast/aggressive, 4–5 feels calmer.
    //   • maxChars  — guards against long words blowing past the safe width.
    //   • lineBreakGap — break when speech pauses (a natural beat) → captions
    //                    breathe with the talker instead of marching in fixed N.
    //   • punctuation — optionally break after . ? ! so a line is a full thought.
    //
    // DEFAULT (chosen per "run the whole plan with sensible defaults"):
    // start a new line whenever ANY of these holds for the incoming word —
    //   • the current line already has `maxWords` words, OR
    //   • adding the word would push the rendered line past `maxChars`, OR
    //   • the silence before the word exceeds `lineBreakGap` (a natural beat), OR
    //   • the previous word ended a sentence (. ? !) — one line ≈ one thought.
    // An over-long single word still lands alone rather than being dropped.
    // ─────────────────────────────────────────────────────────────────────────
    private static func groupIntoLines(
        _ words: [CaptionWord], maxWords: Int, maxChars: Int, lineBreakGap: Double
    ) -> [CaptionLine] {
        guard !words.isEmpty else { return [] }
        let sentenceEnders: Set<Character> = [".", "?", "!", "…"]

        var lines: [CaptionLine] = []
        var bucket: [CaptionWord] = []

        func flush() {
            guard let first = bucket.first, let last = bucket.last else { return }
            lines.append(CaptionLine(words: bucket, start: first.start, end: last.end))
            bucket = []
        }

        for word in words {
            if let last = bucket.last {
                let lineChars = bucket.reduce(0) { $0 + $1.text.count } + (bucket.count - 1)
                let wouldOverflow = lineChars + 1 + word.text.count > maxChars
                let pause = word.start - last.end > lineBreakGap
                let endsSentence = last.text.last.map(sentenceEnders.contains) ?? false
                if bucket.count >= maxWords || wouldOverflow || pause || endsSentence {
                    flush()
                }
            }
            bucket.append(word)
        }
        flush()
        return lines
    }
}
