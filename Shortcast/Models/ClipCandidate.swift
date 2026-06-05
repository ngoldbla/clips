import Foundation

/// One viral moment the Director (Qwen 3.5 9B) picked out of a long video's
/// transcript: a time range plus why it works and a suggested on-screen hook.
/// `Codable` so finished jobs persist to the local library (Phase 3).
struct ClipCandidate: Sendable, Identifiable, Equatable, Codable {
    var id = UUID()
    /// Start offset in seconds.
    var start: Double
    /// End offset in seconds.
    var end: Double
    /// Editorial rationale ("why this is viral").
    var why: String
    /// Suggested scroll-stopping first line (used for the caption).
    var hook: String
    /// Short on-screen text hook (a few words) for the burned-in overlay.
    var overlay: String = ""

    /// Virality score the Director assigns, 1–10 (hook strength, emotional peak,
    /// payoff/completeness). Drives dedup + ranking. Defaults to a neutral 5 when
    /// the model omits it, so un-scored clips aren't unfairly sunk.
    var score: Double = 5

    /// The 3-platform caption package, when the Director writes it inline in the
    /// same pass (Qwen copywriter). Empty when captions are produced separately
    /// (Gemma copywriter, which watches each cut clip).
    var variants: [PostVariant] = []

    var duration: Double { end - start }

    /// `m:ss–m:ss`, e.g. `0:51–1:09`.
    var rangeLabel: String {
        Self.label(start) + "–" + Self.label(end)
    }

    private static func label(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
