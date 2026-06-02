import Foundation

/// Per-model decoding configuration for the MLX text models Shortcast loads
/// directly (currently just Qwen 3.5 9B, the "Director" that finds viral
/// moments). Adapted from Hermes-Jarvis, trimmed to what Shortcast needs.
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

    /// Vendor-recommended decoding parameters.
    let sampling: SamplingConfig

    /// Qwen 3.5 9B — best multilingual reasoning in the small-model tier, huge
    /// context window (the whole transcript fits in one pass). Loads as a VLM.
    static let qwen35_9b = ChatModelProfile(
        modelID: "mlx-community/Qwen3.5-9B-MLX-4bit",
        displayName: "Qwen 3.5 9B",
        factoryKind: .vlm,
        // Qwen3 non-thinking recommended sampling (temp 0.7 / topP 0.8 / topK 20).
        // Thinking is forced OFF via additionalContext, so these are correct.
        // maxTokens bumped from Hermes' 1536 → 4096: the clips JSON for a long
        // video can be long and must not truncate. KV bounded + 8-bit to cap
        // memory while still fitting a ~30k-token transcript prefill.
        sampling: SamplingConfig(
            temperature: 0.7, topP: 0.8, topK: 20, minP: 0,
            repetitionPenalty: nil, maxTokens: 4096,
            maxKVSize: 40960, kvBits: 8))
}
