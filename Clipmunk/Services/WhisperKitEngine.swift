import Foundation
@preconcurrency import WhisperKit

/// WhisperKit ASR — multilingual, accurate, ~2 GB CoreML. The STT fallback
/// (Parakeet is preferred on constrained Macs) and the non-English path. This is
/// the pre-existing transcription code, now behind `ASREngine`.
@MainActor
final class WhisperKitEngine: ASREngine {

    private var whisper: WhisperKit?

    /// Whisper variants to prefer, best-first; falls back to the device default
    /// (`openai_whisper-base`, which is multilingual). MUST be multilingual —
    /// distil-* models are English-only and turn other languages into phonetic
    /// gibberish, so they are deliberately excluded.
    private static let preferredVariants = [
        // Full large-v3 transcribes Spanish (and other languages) reliably. The
        // turbo variant was faster on paper but mis-decoded non-English audio
        // here, so it's deliberately not preferred.
        "openai_whisper-large-v3",
        "openai_whisper-large-v3_947MB",
        "openai_whisper-small",
    ]

    var isLoaded: Bool { whisper != nil }

    func transcribe(
        audioURL: URL, languageHint: String,
        onPhase: @escaping @MainActor (TranscriptionService.Phase) -> Void
    ) async throws -> Transcript {
        if whisper == nil {
            onPhase(.downloadingModel(fraction: 0))
            let support = WhisperKit.recommendedModels()
            let variant = Self.preferredVariants.first { support.supported.contains($0) }
                ?? support.default
            TranscriptionService.log("whisper variant: \(variant) (supported: \(support.supported.joined(separator: ", ")))")
            // WhisperKit 1.0: download() returns URL directly (was a wrapper type in 0.9;
            // folder.path below is URL.path, which compiles unchanged).
            // progressCallback: trailing closure still matches ProgressCallback = @Sendable (Progress)->Void.
            let folder = try await WhisperKit.download(variant: variant) { @Sendable progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    onPhase(fraction < 1.0 ? .downloadingModel(fraction: fraction) : .preparingModel)
                }
            }
            // Loading specialises the CoreML model for the chosen compute units.
            // WhisperKit defaults the audio encoder to the Neural Engine, whose
            // specialization of large-v3 is pathologically slow on an M1 Pro
            // (~5 min). Forcing GPU skips that ANE specialization and loads +
            // transcribes far faster, with no first-run stall.
            onPhase(.preparingModel)
            TranscriptionService.log("preparing/loading model \(variant) on GPU…")
            let compute = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU)
            whisper = try await WhisperKit(WhisperKitConfig(
                modelFolder: folder.path, computeOptions: compute, load: true))
            TranscriptionService.log("model loaded")
        }
        guard let whisper else { throw TranscriptionError.modelUnavailable }

        onPhase(.transcribing)
        // Force language detection (or the user's override) so Spanish audio
        // isn't silently decoded as English. `language` nil + detectLanguage true
        // makes WhisperKit pick the spoken language instead of defaulting to en.
        var options = DecodingOptions()
        options.task = .transcribe
        // Ask Whisper for per-word timing so captions can highlight the spoken
        // word. Only this on-device path pays the (small) extra cost; cue-level
        // sources synthesize their stamps instead.
        options.wordTimestamps = true
        if let code = TranscriptionService.languageCode(from: languageHint) {
            options.language = code
            options.detectLanguage = false
            TranscriptionService.log("forcing decode language: \(code)")
        } else {
            options.detectLanguage = true
        }
        let results = try await whisper.transcribe(audioPath: audioURL.path, decodeOptions: options)
        let segments = results.flatMap(\.segments).map { seg in
            TranscriptSegment(
                start: Double(seg.start),
                end: Double(seg.end),
                text: seg.text,
                // WhisperKit's `word` carries a leading space — trim it; drop any
                // empties so the caption stream is clean.
                words: (seg.words ?? []).compactMap { w in
                    let t = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? nil : WordStamp(text: t, start: Double(w.start), end: Double(w.end))
                })
        }
        guard !segments.isEmpty else { throw TranscriptionError.empty }
        TranscriptionService.log("transcribed \(segments.count) segments, language=\(results.first?.language ?? "?")")
        return Transcript(segments: segments, language: results.first?.language)
    }

    func unload() {
        guard whisper != nil else { return }
        whisper = nil
        TranscriptionService.log("whisper unloaded to free memory before the Director")
    }
}
