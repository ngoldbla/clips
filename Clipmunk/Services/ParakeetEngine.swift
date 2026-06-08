import Foundation

/// Turns Parakeet's timestamp-less utterance texts into `TranscriptSegment`s by
/// distributing the known total audio duration across them in proportion to each
/// utterance's character length. Word stamps are left empty on purpose — the
/// existing `Transcript.synthesizeWords` fills them per segment, which keeps the
/// proportional drift bounded to a single short utterance (decision §14.1).
enum ParakeetSegmenter {
    static func segmentize(utterances: [String], totalDuration: Double) -> [TranscriptSegment] {
        let clean = utterances
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !clean.isEmpty, totalDuration > 0 else { return [] }

        let weights = clean.map { Double(max(1, $0.count)) }
        let total = weights.reduce(0, +)
        var cursor = 0.0
        var segments: [TranscriptSegment] = []
        for (i, text) in clean.enumerated() {
            let end = (i == clean.count - 1) ? totalDuration
                                             : cursor + totalDuration * (weights[i] / total)
            segments.append(TranscriptSegment(start: cursor, end: max(end, cursor), text: text, words: []))
            cursor = end
        }
        return segments
    }
}
