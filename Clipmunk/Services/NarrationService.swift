import Foundation
import KokoroTTS

/// Owns the single Kokoro-82M model and synthesizes narration audio. An `actor`
/// so the model (one CoreML instance) is never used concurrently. ~200 MB, loads
/// lazily at render time (after the Director is freed), and can be unloaded.
actor NarrationService {

    static let shared = NarrationService()

    /// Kokoro's fixed output sample rate (verified in source: `outputSampleRate`).
    static let sampleRate: Double = 24000

    private var model: KokoroTTSModel?

    /// Synthesizes `text` in `voiceID` to 24 kHz mono Float32 samples.
    ///
    /// Kokoro's E2E CoreML graph has a fixed 128-phoneme input (~5 s of speech)
    /// and silently truncates longer text, so a full script is chunked into
    /// budget-sized pieces, each synthesized, then stitched with a short silence
    /// gap for natural pacing. Call `synthesize(text:voice:)` directly — NOT the
    /// protocol `generate()`, which hardwires the default voice and ignores
    /// `voiceID`. language/speed keep their defaults ("en", 1.0).
    func synthesize(text: String, voiceID: String) async throws -> [Float] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw NarrationError.emptyScript }
        if model == nil { model = try await KokoroTTSModel.fromPretrained() }
        guard let model else { throw NarrationError.modelUnavailable }

        let chunks = Self.chunk(clean)
        let gap = [Float](repeating: 0, count: Int(0.12 * Self.sampleRate))
        var out: [Float] = []
        for (i, piece) in chunks.enumerated() {
            let samples = try model.synthesize(text: piece, voice: voiceID)
            if i > 0 && !samples.isEmpty { out.append(contentsOf: gap) }
            out.append(contentsOf: samples)
        }
        guard !out.isEmpty else { throw NarrationError.emptyAudio }
        return out
    }

    func unload() { model = nil }

    /// Splits narration text into pieces that each stay under Kokoro's fixed
    /// 128-phoneme budget (~5 s). Greedily packs whole sentences up to `maxChars`
    /// (a conservative proxy for the phoneme budget), splitting any single
    /// sentence longer than the budget by words. Pure → unit-testable.
    static func chunk(_ text: String, maxChars: Int = 100) -> [String] {
        // Split into sentences on . ? ! while keeping the delimiter.
        var sentences: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if ch == "." || ch == "?" || ch == "!" {
                let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { sentences.append(t) }
                cur = ""
            }
        }
        let tail = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        if sentences.isEmpty { sentences = [text] }

        var chunks: [String] = []
        var buf = ""
        func flush() {
            let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { chunks.append(t) }
            buf = ""
        }
        for s in sentences {
            if s.count > maxChars {
                // Oversized sentence: emit the buffer, then pack this by words.
                flush()
                var wbuf = ""
                for word in s.split(separator: " ").map(String.init) {
                    if !wbuf.isEmpty && wbuf.count + word.count + 1 > maxChars {
                        chunks.append(wbuf); wbuf = ""
                    }
                    wbuf += (wbuf.isEmpty ? "" : " ") + word
                }
                if !wbuf.isEmpty { chunks.append(wbuf) }
            } else if !buf.isEmpty && buf.count + s.count + 1 > maxChars {
                flush(); buf = s
            } else {
                buf += (buf.isEmpty ? "" : " ") + s
            }
        }
        flush()
        return chunks.isEmpty ? [text] : chunks
    }

    enum NarrationError: LocalizedError {
        case emptyScript, modelUnavailable, emptyAudio
        var errorDescription: String? {
            switch self {
            case .emptyScript:      return "There's no script text to narrate."
            case .modelUnavailable: return "The narration voice couldn't be loaded."
            case .emptyAudio:       return "Narration produced no audio."
            }
        }
    }
}
