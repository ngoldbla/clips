import Foundation

/// Per-model decoding configuration for the MLX text model Clipmunk loads as the
/// "Director" (Gemma 4 E2B — finds viral moments and writes captions in one pass).
/// Trimmed to what Clipmunk needs.
///
/// MLX `GenerateParameters` defaults are generic; each model family has its
/// own vendor-recommended sampling that materially affects quality and memory.
struct SamplingConfig: Sendable {
    var temperature: Float
    var topP: Float
    /// 0 disables top-k.
    var topK: Int
    /// 0 disables min-p.
    var minP: Float
    /// nil → no repetition penalty.
    var repetitionPenalty: Float?
    /// Hard cap on generated tokens.
    var maxTokens: Int
    /// nil → unbounded (full) KV cache; set to bound memory.
    var maxKVSize: Int?
    /// nil → no KV quantization.
    var kvBits: Int?
}

struct ChatModelProfile: Sendable {
    /// HuggingFace repo id for the main model.
    let modelID: String
    /// Display name shown in UI.
    let displayName: String

    enum FactoryKind { case llm, vlm }
    /// LLM for text-only models; VLM for multimodal packages (Qwen 3.5 9B only
    /// exists in vision-language form on HF, so it loads via VLMModelFactory).
    let factoryKind: FactoryKind

    /// How the weights get turned into a `ModelContainer`. Both paths produce a
    /// container that drives the same `ChatSession` text generation — they only
    /// differ in how the architecture is registered/loaded.
    enum Loader {
        /// Standard mlx-swift-lm factory (Qwen 3.5 ships as a VLM package).
        case vlm
        /// Gemma 4 — register the custom "gemma4" type (text-only) via the
        /// vendored Gemma4Swift package, then load with its tokenizer loader.
        case gemma4Text
    }
    let loader: Loader

    /// Vendor-recommended decoding parameters.
    let sampling: SamplingConfig

    /// Gemma 4 E2B — the sole Director. A ~2.3B-effective gemma4-family model fed
    /// the transcript text only, so it runs as a text LLM through the vendored
    /// Gemma4Swift `.gemma4Text` registration (the same path the old 12B used).
    /// 128K context, so a full long-video transcript still fits in one pass —
    /// finds the moments AND writes each clip's captions inline.
    ///
    /// Repo id + display name come from `ModelCatalog.director` so the name shown
    /// in the UI can never drift from what loads.
    static let director = ChatModelProfile(
        modelID: ModelCatalog.director.repoID,
        displayName: ModelCatalog.director.displayName,
        factoryKind: .llm,
        loader: .gemma4Text,
        // Moderate temperature + a repetition penalty: we need strict JSON, and a
        // small model drifts both ways — too hot mis-samples a structural token
        // and breaks the JSON, too cold falls into a repetition loop that eats the
        // token budget. 0.35 sits between, and repetitionPenalty kills the loops.
        // KV left unquantized (kvBits nil) — simplest, and E2B's footprint is tiny
        // even with a full-precision cache over a transcript.
        sampling: SamplingConfig(
            temperature: 0.35, topP: 0.9, topK: 30, minP: 0,
            repetitionPenalty: 1.1, maxTokens: 4096,
            maxKVSize: nil, kvBits: nil))
}
