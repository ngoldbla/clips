import Foundation
import Gemma4Swift

/// Orchestrates one end-to-end generation: pull the audio out of the video,
/// build the prompt, run Gemma 4 on-device, and parse the result into the
/// three platform variants.
enum GemmaService {

    static func generate(
        job: VideoJob,
        engine: Gemma4Engine,
        languageOverride: String,
        styleExamples: String,
        onToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> GenerationResult {

        let audioURL = try await MediaExtractor.extractAudio(from: job.url)
        defer {
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        }

        let prompt = PromptBuilder.buildPrompt(
            languageOverride: languageOverride,
            styleExamples: styleExamples)

        let media = Gemma4Engine.MediaInput(videoURL: job.url, audioURL: audioURL)
        let raw = try await engine.describe(media: media, prompt: prompt, onToken: onToken)
        return try JSONVariantParser.parse(raw)
    }
}
