import Foundation
import Observation
@preconcurrency import WhisperKit

/// One spoken segment with its time range, in seconds.
struct TranscriptSegment: Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// A full transcript with timestamps. Fed to the Director to pick moments, and
/// sliced per clip to ground each caption in what's actually said there.
struct Transcript: Sendable, Equatable {
    let segments: [TranscriptSegment]
    let language: String?

    var fullText: String {
        segments.map(\.text).joined(separator: " ")
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

    private static func mmss(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Produces a `Transcript` for a long video. Prefers an existing `.srt`/`.vtt`
/// sidecar (instant, no download); falls back to on-device WhisperKit only when
/// none is found — so the Whisper model never downloads for users who already
/// have transcripts.
@MainActor
@Observable
final class TranscriptionService {

    enum Phase: Equatable {
        case idle
        case downloadingModel(fraction: Double)
        case transcribing
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var whisper: WhisperKit?

    /// Whisper variants to prefer, best-first; falls back to the device default
    /// (`openai_whisper-base`, which is multilingual). MUST be multilingual —
    /// distil-* models are English-only and turn other languages into phonetic
    /// gibberish, so they are deliberately excluded.
    private static let preferredVariants = [
        "openai_whisper-large-v3-v20240930_turbo",
        "openai_whisper-large-v3_turbo",
        "openai_whisper-large-v3",
        "openai_whisper-small",
    ]

    // MARK: - Public

    /// Returns a transcript for `videoURL`, using a sidecar `.srt`/`.vtt` if one
    /// sits next to it, otherwise transcribing on-device.
    func transcript(for videoURL: URL) async throws -> Transcript {
        if let sidecar = Self.findSidecar(for: videoURL),
           let parsed = Self.parseSubtitles(at: sidecar) {
            phase = .ready
            return parsed
        }
        return try await transcribeOnDevice(videoURL)
    }

    /// True when a usable transcript exists without needing Whisper.
    static func hasSidecar(for videoURL: URL) -> Bool {
        findSidecar(for: videoURL) != nil
    }

    // MARK: - WhisperKit path

    private func transcribeOnDevice(_ videoURL: URL) async throws -> Transcript {
        // Full audio (no cap) → temp .m4a.
        guard let audioURL = try await MediaExtractor.extractAudio(from: videoURL, maxSeconds: nil) else {
            throw TranscriptionError.noAudio
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        if whisper == nil {
            phase = .downloadingModel(fraction: 0)
            let support = WhisperKit.recommendedModels()
            let variant = Self.preferredVariants.first { support.supported.contains($0) }
                ?? support.default
            Self.log("whisper variant: \(variant) (supported: \(support.supported.joined(separator: ", ")))")
            let folder = try await WhisperKit.download(variant: variant) { @Sendable [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    self?.phase = .downloadingModel(fraction: fraction)
                }
            }
            whisper = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, load: true))
        }

        guard let whisper else { throw TranscriptionError.modelUnavailable }

        phase = .transcribing
        let results = try await whisper.transcribe(audioPath: audioURL.path)
        let segments = results.flatMap(\.segments).map {
            TranscriptSegment(start: Double($0.start), end: Double($0.end), text: $0.text)
        }
        guard !segments.isEmpty else { throw TranscriptionError.empty }
        Self.log("transcribed \(segments.count) segments, language=\(results.first?.language ?? "?")")
        phase = .ready
        return Transcript(segments: segments, language: results.first?.language)
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[shortcast/transcribe] \(message)\n".utf8))
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
