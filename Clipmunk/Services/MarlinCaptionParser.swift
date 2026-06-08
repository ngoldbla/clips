import Foundation

/// One time-ranged thing Marlin saw happening in the video. Timestamps are in
/// **absolute video seconds** once a chunk's local spans have been offset.
struct VisualEvent: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

/// What Marlin saw across one bounded window of the video. The `scene` paragraph
/// is the high-value signal (it reads on-screen text, names B-roll, and orders
/// the visual narrative); `events` are finer `<t1-t2>` spans, kept for the
/// `find()` refinement (mode C) but secondary.
struct VisualWindow: Equatable, Sendable {
    var start: Double
    var end: Double
    var scene: String
    var events: [VisualEvent]
}

/// The perception track: what is on screen and when, across the whole video.
/// Produced by `VisualMapper` (Marlin-2B) and merged into the Director's
/// transcript so the moment-finder can see, not just read.
struct VisualTimeline: Sendable {
    var windows: [VisualWindow]

    /// Empty timeline — the safe fallback when the vision pass is off or fails,
    /// so the Director simply runs transcript-only (today's behavior).
    static let empty = VisualTimeline(windows: [])

    var isEmpty: Bool { windows.allSatisfy { $0.scene.isEmpty && $0.events.isEmpty } }

    var allEvents: [VisualEvent] { windows.flatMap(\.events) }
}

/// Parses Marlin-2B's two trained output formats. Pure string→data; mirrors
/// `modeling_marlin.py` (`parse_caption`, `parse_span`, `strip_thinking`) so the
/// Swift app reproduces the reference behavior exactly. Kept dependency-free and
/// pure so it is trivially testable against captured model output.
enum MarlinCaptionParser {

    // MARK: Trained prompts (must match modeling_marlin.py exactly)

    /// Mode 1 — dense caption. Diverging from the training string degrades quality.
    static let captionPrompt = """
        Provide a spatial description of this clip followed by time-ranged events.
        For each event, give the time range as <start - end> and a short description.
        """

    /// Mode 2 — temporal grounding (the `find()` refinement, mode C). `{event}` is
    /// replaced by the natural-language event to locate.
    static func groundingPrompt(event: String) -> String {
        "Identify the timestamps during which \"\(event)\" takes place. "
            + "Output the time range as \"From <start> to <end>.\" (numbers in seconds)."
    }

    // MARK: Thinking-tag stripping

    /// ms-swift's Marlin template prefixes responses with a bare `<think>\n`
    /// (and the model sometimes emits a full `<think>…</think>` block). Strip
    /// both, like the reference `strip_thinking`.
    static func stripThinking(_ text: String) -> String {
        var out = replacing(text, #"<think>[\s\S]*?</think>\s*"#, with: "")
        out = replacing(out, #"^\s*<think>\s*\n*"#, with: "")
        out = replacing(out, #"</think>\s*"#, with: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Mode 1 — dense caption

    /// Parses a caption into `(scene, events)`. Tolerant: if `Scene:`/`Events:`
    /// headers are missing, scene = text before the first event line and events
    /// = whatever event-shaped lines were found. Spans are chunk-local seconds.
    static func parseCaption(_ raw: String) -> (scene: String, events: [VisualEvent]) {
        let cleaned = stripThinking(raw)

        let scene: String
        if let s = firstGroup(cleaned, #"(?:^|\n)\s*Scene\s*:\s*([\s\S]*?)(?=\n\s*Events\s*:|\z)"#) {
            scene = s.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // Fallback: everything before the first event-shaped line.
            var lines: [String] = []
            for line in cleaned.split(separator: "\n", omittingEmptySubsequences: false) {
                if parseEventLine(String(line)) != nil { break }
                lines.append(String(line))
            }
            scene = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let eventsBlock = firstGroup(cleaned, #"(?:^|\n)\s*Events\s*:\s*([\s\S]*)\z"#) ?? cleaned
        let events = eventsBlock
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { parseEventLine(String($0)) }

        return (scene, events)
    }

    /// Parses one `<start - end> description` line (tolerating units and missing
    /// angle brackets), or nil if the line isn't event-shaped / is degenerate.
    static func parseEventLine(_ line: String) -> VisualEvent? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let pattern = #"^\s*<?\s*(\d+\.?\d*)\s*(?:seconds?|secs?|s)?\s*-\s*(\d+\.?\d*)\s*(?:seconds?|secs?|s)?\s*>?\s*[:\-]?\s*(.+?)\s*$"#
        guard let m = match(s, pattern), m.count >= 4,
              let start = Double(m[1]), let end = Double(m[2]) else { return nil }
        let desc = m[3].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .trimmingCharacters(in: .whitespaces)
        guard end > start, !desc.isEmpty else { return nil }
        return VisualEvent(start: start, end: end, text: desc)
    }

    // MARK: Mode 2 — temporal grounding

    /// Parses `From X to Y.` → `(start, end)` chunk-local seconds, or nil.
    static func parseSpan(_ raw: String) -> (start: Double, end: Double)? {
        let cleaned = stripThinking(raw)
        guard let m = match(cleaned, #"From\s+(\d+\.?\d*)\s*(?:s|sec)?\s+to\s+(\d+\.?\d*)\s*(?:s|sec)?\.?"#),
              m.count >= 3, let start = Double(m[1]), let end = Double(m[2]), end > start
        else { return nil }
        return (start, end)
    }

    // MARK: Regex helpers (NSRegularExpression, case-insensitive)

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Returns capture groups [full, g1, g2, …] for the first match, or nil.
    private static func match(_ s: String, _ pattern: String) -> [String]? {
        guard let re = regex(pattern) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range) else { return nil }
        return (0..<m.numberOfRanges).map {
            Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? ""
        }
    }

    private static func firstGroup(_ s: String, _ pattern: String) -> String? {
        match(s, pattern).flatMap { $0.count > 1 ? $0[1] : nil }
    }

    private static func replacing(_ s: String, _ pattern: String, with repl: String) -> String {
        guard let re = regex(pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: repl)
    }
}
