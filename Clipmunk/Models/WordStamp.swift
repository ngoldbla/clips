import Foundation

/// One spoken word with its time range, in seconds.
///
/// Lives in its own file — deliberately free of any `import WhisperKit` — so the
/// caption types built on top of it (`CaptionScript`, `CaptionRenderer`) and the
/// headless `clipmunk-probe` target can use word timing without dragging the
/// Whisper model dependency into a target that doesn't want it.
///
/// `Codable` so finished jobs can persist their word timings in the local job
/// library; `Sendable` so it crosses the `nonisolated` sampling/render boundary
/// the same way `TranscriptSegment` does.
struct WordStamp: Sendable, Equatable, Codable {
    let text: String
    let start: Double
    let end: Double
}
