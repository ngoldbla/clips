import Foundation

/// The single source of truth for every on-device model's identity: its
/// HuggingFace repo id, the name shown in the UI, and an approximate footprint.
///
/// Why this exists: model names used to be string literals scattered across
/// views, services and comments, so when a default changed the strings rotted
/// (the processing screen said "Gemma 4 12B is scanning" while a different model
/// was actually selected; Settings said "large-v3-turbo" while the code loaded
/// "large-v3"). Everything user-facing now reads from here — or from the
/// actually-loaded model — so a displayed name can never drift from what runs.
///
/// The collapsed lineup: one small LLM (Gemma 4 E2B) that finds the moments AND
/// writes the captions, Marlin-2B for the optional visual map, and Parakeet /
/// WhisperKit for transcription.
enum ModelCatalog {

    enum Role: Sendable { case director, vision, stt, tts }

    struct Entry: Sendable {
        let role: Role
        /// Canonical HuggingFace repo id (or WhisperKit variant name for ASR).
        let repoID: String
        /// The one place a user-facing model name lives.
        let displayName: String
        /// Rough peak resident footprint in GB — informs the download screen and
        /// the memory policy, not a hard limit.
        let estPeakRAMGB: Double
    }

    /// The sole LLM. Finds viral moments and writes each clip's 3-platform
    /// captions in one pass. Loads text-only through the vendored Gemma4Swift
    /// `.gemma4Text` path; 128K context, so a full transcript still fits in a
    /// single pass.
    ///
    /// Validated head-to-head against the standard MLX 4-bit build
    /// (`mlx-community/gemma-4-e2b-it-4bit`): both load and produce 5/5 clips with
    /// 100%-valid JSON; the unsloth Unsloth-Dynamic build is marginally faster on
    /// prefill, so it's preferred. The standard build is the proven fallback —
    /// swap the repo id here (or via the DEBUG `CLIPMUNK_DIRECTOR_MODEL` override).
    static let director = Entry(
        role: .director,
        repoID: "unsloth/gemma-4-E2B-it-UD-MLX-4bit",
        displayName: "Gemma 4 E2B",
        estPeakRAMGB: 3.6)

    /// The optional perception layer. Watches the footage and hands the Director
    /// a timestamped "what's on screen, when" track. Unchanged from before.
    static let vision = Entry(
        role: .vision,
        repoID: "junwatu/Marlin-2B-MLX-8bit",
        displayName: "Marlin-2B",
        estPeakRAMGB: 2.5)

    /// Transcription. The name shown in Settings; the engine that actually runs
    /// (Parakeet on low-memory Macs, WhisperKit otherwise / non-English) is
    /// selected at runtime by `TranscriptionService`.
    static let transcription = Entry(
        role: .stt,
        repoID: "openai_whisper-large-v3",
        displayName: "WhisperKit · large-v3",
        estPeakRAMGB: 2.0)

    /// Low-memory ASR (CoreML/ANE) via speech-swift's streaming Parakeet. Preferred
    /// on constrained Macs for English/unset audio; any failure falls back to
    /// `transcription` (WhisperKit). The repo id is the streaming EOU model that
    /// `ParakeetStreamingASRModel.fromPretrained()` actually downloads.
    static let stt = Entry(
        role: .stt,
        repoID: "aufklarer/Parakeet-EOU-120M-CoreML-INT8",
        displayName: "Parakeet",
        estPeakRAMGB: 0.6)

    /// Faceless-narration TTS (CoreML/ANE) via speech-swift's Kokoro-82M.
    /// Synthesizes the clip's script; the picker enumerates installed voices at
    /// runtime from the model bundle's `voices/*.json`.
    static let tts = Entry(
        role: .tts,
        repoID: "aufklarer/Kokoro-82M-CoreML",
        displayName: "Kokoro-82M",
        estPeakRAMGB: 0.2)
}
