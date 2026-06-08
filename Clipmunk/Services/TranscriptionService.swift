import Foundation
import NaturalLanguage
import Observation

/// One spoken segment with its time range, in seconds.
///
/// `words` carries per-word timing when it's available (WhisperKit with
/// `wordTimestamps` on); it's empty for cue-level sources (`.srt`/`.vtt`
/// sidecars, fetched CC), which synthesize their stamps on demand in
/// `Transcript.wordStamps(start:end:)`. `Codable` so finished jobs can persist
/// their transcript in the local library (Phase 3).
struct TranscriptSegment: Sendable, Equatable, Codable {
    let start: Double
    let end: Double
    let text: String
    var words: [WordStamp] = []
}

/// A full transcript with timestamps. Fed to the Director to pick moments, and
/// sliced per clip to ground each caption in what's actually said there.
struct Transcript: Sendable, Equatable, Codable {
    let segments: [TranscriptSegment]
    let language: String?

    var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// Language inferred from the transcript text itself (BCP-47, e.g. "es").
    /// More reliable than Whisper's 30s auto-detect or a small model's guess —
    /// both of which mislabel (Spanish → "en" / pt-BR). Used to lock the caption
    /// language to what's actually spoken.
    var contentLanguage: String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(fullText)
        return recognizer.dominantLanguage?.rawValue
    }

    /// One `[MM:SS] text` line per segment — gives the Director timestamps to
    /// reason over.
    func srtLike() -> String {
        segments.map { "[\(Self.mmss($0.start))] \($0.text.trimmed)" }
            .joined(separator: "\n")
    }

    /// Concatenated text of segments overlapping `[start, end]`.
    func slice(start: Double, end: Double) -> String {
        segments
            .filter { $0.end > start && $0.start < end }
            .map { $0.text.trimmed }
            .joined(separator: " ")
    }

    /// Per-word stamps (in SOURCE-video seconds) for words overlapping
    /// `[start, end]` — the input to animated word-level captions.
    ///
    /// Uses Whisper's real per-word timing when a segment has it; otherwise
    /// synthesizes stamps by spreading a cue's `[start, end]` across its words in
    /// proportion to each word's length, so cue-level sources (`.srt`/`.vtt`,
    /// fetched CC) still drive word-by-word captions. The caller rebases these to
    /// clip-relative time in `CaptionScript.build`.
    func wordStamps(start: Double, end: Double) -> [WordStamp] {
        var out: [WordStamp] = []
        for seg in segments where seg.end > start && seg.start < end {
            let segWords = seg.words.isEmpty
                ? Self.synthesizeWords(text: seg.text, start: seg.start, end: seg.end)
                : seg.words
            out.append(contentsOf: segWords.filter { $0.end > start && $0.start < end })
        }
        return out
    }

    /// Distributes `[start, end]` across the words in `text` proportionally to
    /// each word's character count. Every word gets a floor weight of 1 so short
    /// words and punctuation-only tokens still receive a slice; the last word is
    /// pinned to `end` so rounding can't leave a gap. A zero-length cue yields
    /// zero-length stamps (harmless — they just don't display).
    static func synthesizeWords(text: String, start: Double, end: Double) -> [WordStamp] {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let span = max(end - start, 0)
        let weights = tokens.map { Double(max(1, $0.count)) }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return [] }

        var cursor = start
        var result: [WordStamp] = []
        for (i, token) in tokens.enumerated() {
            let wEnd = (i == tokens.count - 1) ? end : cursor + span * (weights[i] / totalWeight)
            result.append(WordStamp(text: token, start: cursor, end: max(wEnd, cursor)))
            cursor = wEnd
        }
        return result
    }

    private static func mmss(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Produces a `Transcript` for a long video. Prefers an existing `.srt`/`.vtt`
/// sidecar (instant, no download); falls back to on-device ASR only when
/// none is found — so the model never downloads for users who already
/// have transcripts.
@MainActor
@Observable
final class TranscriptionService {

    enum Phase: Equatable {
        case idle
        case downloadingModel(fraction: Double)
        /// After download: WhisperKit compiles/optimises the model for this Mac.
        /// First run only, slow, and reports no progress — hence a distinct phase
        /// so the UI doesn't sit at a misleading "Downloading 100%".
        case preparingModel
        case transcribing
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    private let whisperEngine = WhisperKitEngine()
    // Parakeet is added in a later task; until then this stays nil and the router
    // always uses WhisperKit (behaviour identical to before).
    @ObservationIgnored private var parakeetEngine: ASREngine? = nil

    // MARK: - Public

    /// Returns a transcript for `videoURL`, using a sidecar `.srt`/`.vtt` if one
    /// sits next to it, otherwise transcribing on-device. `languageHint` (e.g.
    /// "es", "Spanish") forces Whisper's decode language; empty = auto-detect.
    func transcript(for videoURL: URL, languageHint: String = "") async throws -> Transcript {
        if let sidecar = Self.findSidecar(for: videoURL),
           let parsed = Self.parseSubtitles(at: sidecar) {
            phase = .ready
            return parsed
        }
        return try await transcribeOnDevice(videoURL, languageHint: languageHint)
    }

    /// True when a usable transcript exists without needing Whisper.
    static func hasSidecar(for videoURL: URL) -> Bool {
        findSidecar(for: videoURL) != nil
    }

    /// Releases the in-memory ASR models (~2 GB of CoreML buffers). The
    /// weights stay cached on disk, so the next transcription reloads quickly. Used
    /// on memory-constrained Macs to free the STT engine before the Director loads —
    /// the two never need to be resident at the same time (transcription fully
    /// precedes moment-finding). No-op for the sidecar/YouTube-CC paths that never
    /// loaded a model.
    func unload() {
        let wasLoaded = whisperEngine.isLoaded || (parakeetEngine?.isLoaded ?? false)
        whisperEngine.unload()
        parakeetEngine?.unload()
        if wasLoaded { phase = .idle }
    }

    // MARK: - On-device ASR router

    private func transcribeOnDevice(_ videoURL: URL, languageHint: String = "") async throws -> Transcript {
        // Full audio (no cap) → temp .m4a.
        guard let audioURL = try await MediaExtractor.extractAudio(from: videoURL, maxSeconds: nil) else {
            throw TranscriptionError.noAudio
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let engine = whisperEngine   // routing added in a later task
        let result = try await engine.transcribe(
            audioURL: audioURL, languageHint: languageHint,
            onPhase: { @MainActor [weak self] p in self?.phase = p })
        phase = .ready
        return result
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[clipmunk/transcribe] \(message)\n".utf8))
    }

    /// Maps a user language hint to a Whisper 2-letter code, or nil to auto-detect.
    /// Accepts codes ("es") and common names ("Spanish", "español").
    static func languageCode(from hint: String) -> String? {
        let h = hint.trimmed.lowercased()
        guard !h.isEmpty else { return nil }
        let names: [String: String] = [
            "spanish": "es", "español": "es", "espanol": "es", "castellano": "es",
            "english": "en", "inglés": "en", "ingles": "en",
            "portuguese": "pt", "português": "pt", "portugues": "pt",
            "french": "fr", "français": "fr", "francais": "fr",
            "german": "de", "alemán": "de", "aleman": "de", "deutsch": "de",
            "italian": "it", "italiano": "it",
            "catalan": "ca", "català": "ca",
        ]
        if let mapped = names[h] { return mapped }
        if h.count == 2 { return h }     // already a code
        return nil
    }

    // MARK: - Sidecar discovery + parsing

    /// Looks for `<basename>.srt` / `<basename>.vtt` next to the video.
    private static func findSidecar(for videoURL: URL) -> URL? {
        let base = videoURL.deletingPathExtension()
        for ext in ["srt", "vtt"] {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Parses an `.srt` or `.vtt` file into a `Transcript`. Tolerant of both
    /// `,` and `.` millisecond separators and optional cue indices/headers.
    static func parseSubtitles(at url: URL) -> Transcript? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var segments: [TranscriptSegment] = []
        // Split into cues on blank lines; a cue is any block with a "-->" line.
        let blocks = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeLineIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timecode(parts[0]),
                  let end = timecode(parts[1])
            else { continue }
            let text = lines[(timeLineIndex + 1)...].joined(separator: " ").trimmed
            guard !text.isEmpty else { continue }
            segments.append(TranscriptSegment(start: start, end: end, text: text))
        }
        guard !segments.isEmpty else { return nil }
        return Transcript(segments: segments, language: nil)
    }

    /// Parses `HH:MM:SS,mmm` / `MM:SS.mmm` (cue settings after the time ignored).
    static func timecode(_ raw: String) -> Double? {
        let token = raw.trimmed
            .split(separator: " ").first.map(String.init) ?? raw.trimmed
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let fields = normalized.split(separator: ":").map { Double($0) ?? 0 }
        switch fields.count {
        case 3: return fields[0] * 3600 + fields[1] * 60 + fields[2]
        case 2: return fields[0] * 60 + fields[1]
        case 1: return fields[0]
        default: return nil
        }
    }
}

enum TranscriptionError: LocalizedError {
    case noAudio
    case modelUnavailable
    case empty

    var errorDescription: String? {
        switch self {
        case .noAudio:          return "That video has no audio to transcribe."
        case .modelUnavailable: return "The transcription model couldn't be loaded."
        case .empty:            return "No speech was found in that video."
        }
    }
}
