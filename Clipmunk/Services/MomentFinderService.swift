import Foundation
import Gemma4Swift
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

    /// Which model plays the Director. Defaults to Gemma 4 12B; switched to match
    /// the user's pick via `setProfile(_:)` before the model loads.
    private(set) var profile = ChatModelProfile.gemma12B

    var isReady: Bool { container != nil }
    var isBusy: Bool {
        switch phase {
        case .downloading, .loading: return true
        default: return false
        }
    }

    var displayName: String { profile.displayName }

    // MLX's Metal allocator (buffer-cache + memory limits) is configured centrally
    // in `MemoryPolicy.configureMLX()` at launch, sized to this Mac's RAM.

    // MARK: - Lifecycle

    /// Switches the Director model. If a different model is already loaded, it's
    /// unloaded so the next `prepareIfNeeded()` brings up the new one.
    func setProfile(_ newProfile: ChatModelProfile) {
        guard newProfile.modelID != profile.modelID else { return }
        if container != nil { unload() }
        profile = newProfile
    }

    /// Downloads (if needed) and loads the selected Director model. Safe to call
    /// repeatedly. Loaded lazily on the first long-video drop — not at app launch.
    func prepareIfNeeded() async {
        guard container == nil, !isBusy else { return }
        phase = .downloading(fraction: 0)

        do {
            let downloader = #hubDownloader()
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
            // Both models feed plain text and generate via ChatSession; they only
            // differ in how the container is built.
            switch profile.loader {
            case .vlm:
                // Qwen 3.5 9B ships only as a VLM package on HF → VLMModelFactory.
                // No chat-template patch is needed for plain text generation.
                container = try await VLMModelFactory.shared.loadContainer(
                    from: localDir, using: #huggingFaceTokenizerLoader())
            case .gemma4Text:
                // Gemma 4 isn't in mlx-swift-lm's registry — register the custom
                // "gemma4" type (text-only: we never pass it media) and load with
                // the package's tokenizer loader.
                await Gemma4Registration.register(multimodal: false)
                container = try await loadModelContainer(
                    from: localDir, using: Gemma4TokenizerLoader())
            }
            phase = .ready
            Self.log("director loaded: \(profile.displayName) (\(profile.modelID))")
        } catch {
            Self.log("director load FAILED for \(profile.modelID): \(error)")
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
    ///
    /// When `includeCaptions` is true, the same pass also writes each clip's
    /// 3-platform caption package — so no separate captioning step is needed.
    func findMoments(
        transcript: String,
        includeCaptions: Bool = false,
        language: String? = nil,
        styleExamples: String = ""
    ) async throws -> [ClipCandidate] {
        guard let container else { throw MomentFinderError.notReady }

        let s = profile.sampling
        var params = GenerateParameters(
            // Captions per clip need much more room than bare moments — a long
            // video can yield 5-6 clips, each with three platforms' caption
            // package (Instagram alone wants 20-30 hashtags). 6144 covers that;
            // the repetition penalty stops runaway loops from filling it.
            maxTokens: includeCaptions ? 6144 : s.maxTokens,
            temperature: s.temperature,
            topP: s.topP,
            topK: s.topK,
            minP: s.minP,
            repetitionPenalty: s.repetitionPenalty)
        params.maxKVSize = s.maxKVSize
        params.kvBits = s.kvBits

        let instructions = includeCaptions
            ? Self.captioningPrompt(language: language, styleExamples: styleExamples)
            : Self.systemPrompt
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: params,
            additionalContext: ["enable_thinking": false])

        let userPrompt = "Transcripción del vídeo (con timestamps):\n\n\(transcript)\n\nDevuelve el JSON de clips."

        Self.log("findMoments: transcript \(transcript.count) chars, captions=\(includeCaptions)")
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
        FileHandle.standardError.write(Data("[clipmunk/director] \(message)\n".utf8))
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
    {"clips":[{"start":"MM:SS","end":"MM:SS","why":"por qué es viral","hook":"primera frase del clip que para el scroll","overlay":"texto MUY corto (3-6 palabras) para sobreimprimir en pantalla","score":8}]}
    - "overlay" es un gancho cortísimo y con punch, en el idioma del vídeo, pensado para verse grande encima del vídeo los primeros segundos.
    - "score": número del 1 al 10 de qué tan viral es (gancho fuerte, pico emocional, payoff/idea completa). 10 = imprescindible.
    - Entre 3 y 6 clips, ordenados de mejor a peor.
    """

    /// A human language name for the model, from a BCP-47 code ("en") or a name
    /// the user already typed ("English"). Prefers the endonym ("English",
    /// "español") — the strongest signal to an LLM about which language to write
    /// in. Returns "" when there's nothing usable (caller then asks the model to
    /// match the transcript's language).
    static func languageName(_ value: String?) -> String {
        let v = (value ?? "").trimmed
        guard !v.isEmpty else { return "" }
        // Looks like a code ("en", "es", "pt-BR") → resolve to its endonym.
        if v.count <= 5, v.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" }) {
            let base = String(v.prefix(2)).lowercased()
            if let endonym = Locale(identifier: base).localizedString(forLanguageCode: base) {
                return endonym
            }
        }
        return v
    }

    /// Combined prompt: find the moments AND write each clip's 3-platform caption
    /// package in the same pass (no separate captioning step). Used for the Qwen
    /// copywriter path.
    static func captioningPrompt(language: String?, styleExamples: String) -> String {
        // The instructions below are in Spanish (validated that way), so the model
        // tends to answer in Spanish unless told otherwise emphatically. Name the
        // target language by its endonym ("English", "español") rather than a bare
        // code, and explicitly call out the instruction/output language mismatch —
        // that's what reliably flips a 9B model to the spoken language.
        let name = Self.languageName(language)
        let languageRule = name.isEmpty
            ? "IMPORTANTE — IDIOMA DE SALIDA: detecta el idioma de la TRANSCRIPCIÓN y escribe TODOS los textos (why, hook, overlay, captions y hashtags) EN ESE MISMO IDIOMA. Aunque estas instrucciones estén en español, NO escribas en español salvo que la transcripción esté en español."
            : "IMPORTANTE — IDIOMA DE SALIDA: escribe TODOS los textos (why, hook, overlay, captions y hashtags) en \(name). Aunque estas instrucciones estén en español, la SALIDA debe estar ÍNTEGRAMENTE en \(name)."

        let style = styleExamples.trimmed
        let styleRule = style.isEmpty ? "" : """

        Voz del creador — imita este estilo (tono, ritmo, emojis, formato):
        \(style)
        """

        return """
        Eres un editor experto en contenido short-form viral (TikTok, Reels, \
        YouTube Shorts). Te doy la transcripción de un vídeo largo, con timestamps. \
        Tu trabajo: encontrar los MEJORES momentos para cortar en clips verticales \
        que enganchen en los 2 primeros segundos, Y para cada clip escribir el \
        paquete de publicación de las 3 redes.

        Reglas:
        - Cada clip dura entre 15 y 50 segundos. Una idea completa, nada cortado a medias.
        - Entre 3 y 6 clips, ordenados de mejor a peor.
        - "score": número del 1 al 10 de qué tan viral es (gancho fuerte, pico emocional, payoff/idea completa). 10 = imprescindible.
        - \(languageRule)
        - Los hashtags van como strings JSON entre comillas, SIN el símbolo '#' (ej: "productividad", "marketing"), y cada uno único (no repitas).
        - Devuelve SOLO un JSON válido, sin texto alrededor, con esta forma EXACTA:
        {"clips":[{
          "start":"MM:SS",
          "end":"MM:SS",
          "why":"por qué es viral",
          "hook":"primera frase del clip que para el scroll",
          "overlay":"texto MUY corto (3-6 palabras) para sobreimprimir en pantalla",
          "score":8,
          "captions":{
            "tiktok":{"hook":"primera línea que para el scroll, máx 90 caracteres","description":"caption corta y con punch","hashtags":["tag","tag","tag"]},
            "instagram":{"hook":"primera línea fuerte","description":"2-4 párrafos cortos, storytelling, acaba con llamada a la acción","hashtags":["...20-30 tags mezclando alcance grande y nicho..."]},
            "youtube":{"hook":"título conciso y buscable, 40-60 caracteres","description":"descripción rica en keywords para búsqueda","hashtags":["...3-5 tags..."]}
          }
        }]}
        - No inventes nada que no esté en la transcripción.\(styleRule)
        """
    }
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
        var entries: [[String: Any]] = []
        if let jsonString = JSONVariantParser.extractJSONObject(from: raw),
           let root = JSONVariantParser.deserializeTolerant(jsonString) as? [String: Any],
           let clipsArray = root["clips"] as? [[String: Any]] {
            entries = clipsArray
        }
        // Fallback: the whole array failed to parse (a token drifted, or the
        // generation was truncated mid-JSON). Salvage every complete clip object
        // on its own, so one broken/cut-off clip doesn't drop all the good ones.
        if entries.isEmpty {
            entries = salvageClipEntries(from: raw)
            if !entries.isEmpty {
                MomentFinderService.log("parser: strict parse failed — salvaged \(entries.count) clip object(s)")
            }
        }
        MomentFinderService.log("parser: \(entries.count) raw clip entries")
        let built = entries.compactMap(buildClip)
        let ranked = rankAndDedup(built, overlapThreshold: overlapThreshold)
        MomentFinderService.log("parser: \(built.count) built → \(ranked.count) after dedup/rank")
        return ranked
    }

    /// Decision #4 default: two clips count as near-duplicates when their time
    /// ranges overlap by more than this fraction of the SHORTER clip.
    static let overlapThreshold = 0.5

    /// Ranks clips best-first by score (tie-break: the longer, more-complete clip
    /// wins) and greedily drops any clip that overlaps an already-kept,
    /// higher-ranked sibling past `overlapThreshold` — so the grid never shows two
    /// cuts of the same moment.
    static func rankAndDedup(_ clips: [ClipCandidate], overlapThreshold: Double) -> [ClipCandidate] {
        let sorted = clips.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.duration > $1.duration
        }
        var kept: [ClipCandidate] = []
        for clip in sorted where !kept.contains(where: { overlapFraction(clip, $0) > overlapThreshold }) {
            kept.append(clip)
        }
        return kept
    }

    /// Overlap of two ranges as a fraction of the shorter one's duration (0…1).
    static func overlapFraction(_ a: ClipCandidate, _ b: ClipCandidate) -> Double {
        let overlap = max(0, min(a.end, b.end) - max(a.start, b.start))
        return overlap / max(1, min(a.duration, b.duration))
    }

    /// Builds a validated `ClipCandidate` from one raw clip object, or nil if it
    /// lacks a usable time range / is too short.
    private static func buildClip(from entry: [String: Any]) -> ClipCandidate? {
        guard let start = seconds(from: entry["start"]),
              let end = seconds(from: entry["end"]),
              end > start
        else { return nil }

        var clip = ClipCandidate(
            start: start,
            end: end,
            why: string(entry, "why", "reason", "rationale"),
            hook: string(entry, "hook", "title", "headline"),
            overlay: string(entry, "overlay", "onscreen", "caption"))
        if let score = scoreValue(entry["score"] ?? entry["rating"] ?? entry["virality"]) {
            clip.score = score
        }

        // Inline 3-platform caption package. The captions object is keyed by
        // platform, which JSONVariantParser already handles.
        if let captions = entry["captions"] ?? entry["posts"],
           let result = try? JSONVariantParser.parse(object: captions) {
            clip.variants = result.variants
        }

        // Validate duration: clamp if too long, drop if too short.
        if clip.duration > maxDuration {
            clip.end = clip.start + maxDuration
        }
        guard clip.duration >= minDuration else { return nil }
        return clip
    }

    /// Scans the raw text for complete balanced `{…}` objects that look like
    /// clips (they carry a "start" and "end"), parsing each independently. This
    /// recovers the good clips even when the enclosing array is truncated (token
    /// limit) or one clip is malformed.
    private static func salvageClipEntries(from raw: String) -> [[String: Any]] {
        let chars = Array(raw)
        var entries: [[String: Any]] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "{", let close = matchingBrace(chars, from: i) else {
                i += 1
                continue
            }
            let candidate = String(chars[i...close])
            if let obj = JSONVariantParser.deserializeTolerant(candidate) as? [String: Any],
               obj["start"] != nil, obj["end"] != nil {
                entries.append(obj)
                i = close + 1
            } else {
                i += 1
            }
        }
        return entries
    }

    /// Index of the `}` matching the `{` at `start`, respecting string literals,
    /// or nil if the object is unbalanced (e.g. truncated).
    private static func matchingBrace(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return i }
                default: break
                }
            }
            i += 1
        }
        return nil
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

    /// Parses a 1–10 score from a number or numeric string, clamped to [1, 10].
    static func scoreValue(_ value: Any?) -> Double? {
        let raw: Double?
        if let n = value as? Double { raw = n }
        else if let n = value as? Int { raw = Double(n) }
        else if let s = value as? String {
            raw = Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        } else { raw = nil }
        return raw.map { min(10, max(1, $0)) }
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
