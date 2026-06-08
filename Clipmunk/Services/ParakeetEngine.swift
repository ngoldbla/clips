import Foundation
@preconcurrency import ParakeetStreamingASR

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

/// Parakeet TDT ASR via soniqo/speech-swift (CoreML/ANE, ~hundreds of MB).
/// Preferred on constrained Macs for English/unset audio. Returns text only
/// (no timestamps) — utterances are time-bounded proportionally by
/// `ParakeetSegmenter`, then word stamps are synthesized downstream.
@MainActor
final class ParakeetEngine: ASREngine {

    private var model: ParakeetStreamingASRModel?

    var isLoaded: Bool { model != nil }

    func transcribe(
        audioURL: URL, languageHint: String,
        onPhase: @escaping @MainActor (TranscriptionService.Phase) -> Void
    ) async throws -> Transcript {
        // Resample off the main actor so a long file doesn't jank the UI.
        let samples = try await Task.detached { try AudioResampler.pcm16kMono(from: audioURL) }.value
        guard !samples.isEmpty else { throw TranscriptionError.empty }
        let totalDuration = Double(samples.count) / 16000.0

        if model == nil {
            onPhase(.downloadingModel(fraction: 0))
            // The progress handler is called from a nonisolated context inside
            // fromPretrained. Capture onPhase in a @Sendable wrapper that hops
            // back to the MainActor so Swift 6's sendability checker is satisfied.
            let reportProgress: @Sendable (Double, String) -> Void = { fraction, _ in
                Task { @MainActor in
                    onPhase(fraction < 1.0 ? .downloadingModel(fraction: fraction) : .preparingModel)
                }
            }
            model = try await ParakeetStreamingASRModel.fromPretrained(
                progressHandler: reportProgress)
        }
        guard let model else { throw TranscriptionError.modelUnavailable }

        onPhase(.transcribing)
        var utteranceText: [Int: String] = [:]
        var order: [Int] = []
        for await partial in model.transcribeStream(audio: samples, sampleRate: 16000, chunkDuration: nil) {
            guard partial.isFinal else { continue }
            if utteranceText[partial.segmentIndex] == nil { order.append(partial.segmentIndex) }
            utteranceText[partial.segmentIndex] = partial.text
        }
        var utterances = order.compactMap { utteranceText[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if utterances.count <= 1, let whole = utterances.first {
            utterances = Self.splitSentences(whole)
        }
        // The EOU streaming model often returns a single long, punctuation-less
        // utterance (it segments on conversational turns, not sentences), which
        // would leave one caption segment spanning the whole clip. Re-chunk into
        // roughly fixed-length pieces (~6 s each) so proportional word drift stays
        // bounded per segment — the per-utterance bound decision §14.1 intends.
        let targetSegments = max(1, Int((totalDuration / 6.0).rounded()))
        if utterances.count < targetSegments {
            let rechunked = Self.chunkByWords(
                utterances.joined(separator: " "), targetSegments: targetSegments)
            if rechunked.count > utterances.count { utterances = rechunked }
        }

        let segments = ParakeetSegmenter.segmentize(utterances: utterances, totalDuration: totalDuration)
        guard !segments.isEmpty else { throw TranscriptionError.empty }
        TranscriptionService.log("parakeet: \(segments.count) utterance segment(s) over \(String(format: "%.1f", totalDuration))s")
        return Transcript(segments: segments, language: TranscriptionService.languageCode(from: languageHint) ?? "en")
    }

    func unload() { model = nil }

    /// Splits a block of text into sentence-ish utterances on . ? ! boundaries.
    private static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "?" || ch == "!" {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out.isEmpty ? [text] : out
    }

    /// Splits `text` into ~`targetSegments` roughly equal word-count chunks. Used
    /// when the streaming model under-segments a long utterance, so each caption
    /// segment spans only a few seconds rather than the whole clip.
    private static func chunkByWords(_ text: String, targetSegments: Int) -> [String] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard targetSegments > 1, words.count > targetSegments else { return [text] }
        let per = max(1, Int((Double(words.count) / Double(targetSegments)).rounded(.up)))
        var out: [String] = []
        var i = 0
        while i < words.count {
            out.append(words[i..<min(i + per, words.count)].joined(separator: " "))
            i += per
        }
        return out
    }
}
