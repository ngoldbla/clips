import Foundation
import HuggingFace
import MLX
import MLXLMCommon
import MLXHuggingFace
import MLXVLM
import Observation
import Tokenizers

/// The "Director": owns the Qwen 3.5 9B text model and turns a full transcript
/// into a ranked list of viral clip candidates in one pass.
///
/// Adapted from Hermes-Jarvis' MLXChatService, stripped of skills/tools, draft
/// models and speculative decoding — this is single-shot structured generation.
/// Qwen 3.5 9B's huge context window swallows an hour-long transcript at once,
/// so there is no chunking. Thinking is forced OFF.
@MainActor
@Observable
final class MomentFinderService {

    enum Phase: Equatable {
        case idle
        case downloading(fraction: Double)
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var container: ModelContainer?

    private let profile = ChatModelProfile.qwen35_9b

    var isReady: Bool { container != nil }
    var isBusy: Bool {
        switch phase {
        case .downloading, .loading: return true
        default: return false
        }
    }

    var displayName: String { profile.displayName }

    init() {
        // Cap MLX's Metal buffer cache so long sessions don't balloon RAM.
        MLX.Memory.cacheLimit = 1024 * 1024 * 1024
    }

    // MARK: - Lifecycle

    /// Downloads (if needed) and loads Qwen 3.5 9B. Safe to call repeatedly.
    /// Loaded lazily on the first long-video drop — not at app launch.
    func prepareIfNeeded() async {
        guard container == nil, !isBusy else { return }
        phase = .downloading(fraction: 0)

        do {
            let downloader = #hubDownloader()
            let tokenizerLoader = #huggingFaceTokenizerLoader()
            let localDir = try await downloader.download(
                id: profile.modelID,
                revision: nil,
                matching: ["*.safetensors", "*.json", "*.txt", "*.jinja"],
                useLatest: false,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        let f = progress.fractionCompleted
                        self.phase = f < 1.0 ? .downloading(fraction: f) : .loading
                    }
                })

            phase = .loading
            // Qwen 3.5 9B ships only as a VLM package on HF → VLMModelFactory.
            // We feed it text only; no chat-template patch is needed because we
            // do plain text generation (the patch only matters for tool calls).
            container = try await VLMModelFactory.shared.loadContainer(
                from: localDir, using: tokenizerLoader)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Frees the loaded model and its Metal cache. Used by ModelManager to make
    /// room for the Gemma copywriter on memory-constrained Macs.
    func unload() {
        container = nil
        phase = .idle
        MLX.Memory.clearCache()
    }

    func resetForRetry() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Generation

    /// Runs one pass over the full transcript and returns ranked clip candidates.
    /// Builds a fresh session per call so one video's KV never leaks into the next.
    func findMoments(transcript: String) async throws -> [ClipCandidate] {
        guard let container else { throw MomentFinderError.notReady }

        let s = profile.sampling
        var params = GenerateParameters(
            maxTokens: s.maxTokens,
            temperature: s.temperature,
            topP: s.topP,
            topK: s.topK,
            minP: s.minP,
            repetitionPenalty: s.repetitionPenalty)
        params.maxKVSize = s.maxKVSize
        params.kvBits = s.kvBits

        let session = ChatSession(
            container,
            instructions: Self.systemPrompt,
            generateParameters: params,
            additionalContext: ["enable_thinking": false])

        let userPrompt = "Transcripción del vídeo (con timestamps):\n\n\(transcript)\n\nDevuelve el JSON de clips."

        Self.log("findMoments: transcript \(transcript.count) chars")
        var raw = ""
        for try await chunk in session.streamResponse(to: userPrompt) {
            raw += chunk
        }
        Self.log("findMoments raw output (\(raw.count) chars):\n\(raw)")

        let clips = MomentJSONParser.parse(raw)
        Self.log("findMoments: parsed \(clips.count) clip(s) after validation")
        guard !clips.isEmpty else { throw MomentFinderError.noClips }
        return clips
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[shortcast/director] \(message)\n".utf8))
    }

    /// Captions one clip from its transcript slice (the text-only Copywriter
    /// path). Reuses the social-content-coach prompt and the standard variant
    /// parser, so it returns the same `GenerationResult` shape as Gemma.
    func caption(
        transcriptSlice: String,
        hook: String,
        languageOverride: String,
        styleExamples: String
    ) async throws -> GenerationResult {
        guard let container else { throw MomentFinderError.notReady }

        let s = profile.sampling
        var params = GenerateParameters(
            maxTokens: 1536,
            temperature: s.temperature,
            topP: s.topP,
            topK: s.topK,
            minP: s.minP,
            repetitionPenalty: s.repetitionPenalty)
        params.maxKVSize = s.maxKVSize
        params.kvBits = s.kvBits

        let session = ChatSession(
            container,
            instructions: PromptBuilder.buildTranscriptPrompt(
                languageOverride: languageOverride, styleExamples: styleExamples),
            generateParameters: params,
            additionalContext: ["enable_thinking": false])

        let user = "Suggested hook: \(hook)\n\nClip transcript:\n\(transcriptSlice)\n\nReturn the JSON package."
        var raw = ""
        for try await chunk in session.streamResponse(to: user) {
            raw += chunk
        }
        return try JSONVariantParser.parse(raw)
    }

    // MARK: - Prompt

    /// The validated Spanish moment-finder prompt (proven on a real 17-min .srt).
    static let systemPrompt = """
    Eres un editor experto en contenido short-form viral (TikTok, Reels, \
    YouTube Shorts). Te doy la transcripción de un vídeo largo, con timestamps. \
    Tu trabajo: encontrar los MEJORES momentos para cortar en clips verticales \
    que funcionen solos y enganchen en los 2 primeros segundos.

    Reglas:
    - Cada clip dura entre 15 y 50 segundos.
    - Elige momentos con gancho, payoff, una idea completa o una frase memorable. \
    NADA de cortar a mitad de idea.
    - Devuelve SOLO un JSON válido, sin texto alrededor, con esta forma:
    {"clips":[{"start":"MM:SS","end":"MM:SS","why":"por qué es viral","hook":"primera frase del clip que para el scroll","overlay":"texto MUY corto (3-6 palabras) para sobreimprimir en pantalla"}]}
    - "overlay" es un gancho cortísimo y con punch, en el idioma del vídeo, pensado para verse grande encima del vídeo los primeros segundos.
    - Entre 3 y 6 clips, ordenados de mejor a peor.
    """
}

enum MomentFinderError: LocalizedError {
    case notReady
    case noClips

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "The moment-finder model is still loading."
        case .noClips:
            return "Couldn't find any usable moments in that video."
        }
    }
}

/// Tolerant parser for the Director's JSON output. Mirrors the balanced-brace
/// scan in `JSONVariantParser`, but reads a `clips` array, normalizes timestamps
/// (numeric seconds, `MM:SS`, or `HH:MM:SS,mmm`) and validates clip durations.
enum MomentJSONParser {

    /// Acceptable clip duration window, in seconds. The model often picks
    /// punchy ~10s moments, so the floor is generous; anything genuinely tiny
    /// is dropped and anything too long is clamped.
    static let minDuration = 8.0
    static let maxDuration = 60.0

    static func parse(_ raw: String) -> [ClipCandidate] {
        guard let jsonString = JSONVariantParser.extractJSONObject(from: raw),
              let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        let entries = (root["clips"] as? [[String: Any]]) ?? []
        MomentFinderService.log("parser: model returned \(entries.count) raw clip entries")
        var clips: [ClipCandidate] = []
        for entry in entries {
            guard let start = seconds(from: entry["start"]),
                  let end = seconds(from: entry["end"]),
                  end > start
            else { continue }

            var clip = ClipCandidate(
                start: start,
                end: end,
                why: string(entry, "why", "reason", "rationale"),
                hook: string(entry, "hook", "title", "headline"),
                overlay: string(entry, "overlay", "onscreen", "caption"))

            // Validate duration: clamp if too long, drop if too short.
            if clip.duration > maxDuration {
                clip.end = clip.start + maxDuration
            }
            guard clip.duration >= minDuration else { continue }

            clips.append(clip)
        }
        return clips
    }

    /// Parses a timestamp value into seconds. Accepts a number, or strings like
    /// `"95"`, `"1:35"`, `"01:35"`, `"00:01:35,200"`, `"1:35.2"`.
    static func seconds(from value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        guard let str = (value as? String)?.trimmingCharacters(in: .whitespaces),
              !str.isEmpty else { return nil }

        // Plain number string.
        if let n = Double(str.replacingOccurrences(of: ",", with: ".")),
           !str.contains(":") {
            return n
        }

        // Colon-separated H:M:S / M:S. Last field may use ',' or '.' for ms.
        let parts = str.split(separator: ":").map {
            Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0
        }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return nil
        }
    }

    private static func string(_ entry: [String: Any], _ keys: String...) -> String {
        for key in keys {
            if let value = (entry[key] as? String)?.trimmed, !value.isEmpty {
                return value
            }
        }
        return ""
    }
}
