import Foundation
import Gemma4Swift
import HuggingFace
import MLX
import MLXLMCommon
import MLXHuggingFace
import MLXVLM
import Observation
import Tokenizers

/// The "Director": owns the Gemma 4 E2B text model and turns a full transcript
/// into a ranked list of viral clip candidates — writing each clip's captions in
/// the same pass.
///
/// Single-shot structured generation (no skills/tools, draft models or
/// speculative decoding). E2B's 128K context swallows an hour-long transcript at
/// once, so there is no chunking. Thinking is forced OFF.
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

    /// Which model plays the Director. There's a single option now (Gemma 4 E2B);
    /// the field stays so the load/switch plumbing is unchanged.
    private(set) var profile = ChatModelProfile.director

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
            // Director repo is public; pass the token anyway so a gated mirror
            // (or a future gated Director) keeps working.
            let downloader = ClipmunkModelDownloader(token: HFToken.resolve())
            let localDir = try await downloader.download(
                id: Self.effectiveModelID(profile.modelID),
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
            let id = Self.effectiveModelID(profile.modelID)
            if Self.isCorruptDownload(error) {
                // A half-finished / truncated weights file. Purge it so a retry
                // re-downloads cleanly instead of failing on the same broken file,
                // and show a clear message rather than the raw MLX error.
                Self.purgeModelCache(id)
                Self.log("director load FAILED (incomplete/corrupt download) for \(id) — cache purged: \(error)")
                phase = .failed("That model's download was incomplete or corrupted — it's been cleared. Tap Retry to download it again.")
            } else {
                Self.log("director load FAILED for \(id): \(error)")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// True when a model-load error looks like a truncated/corrupt weights file (a
    /// download that didn't finish) rather than, say, an out-of-memory error — the
    /// signature is a malformed safetensors header.
    nonisolated static func isCorruptDownload(_ error: Error) -> Bool {
        let s = "\(error)".lowercased()
        return s.contains("invalid json header") || s.contains("header length")
            || s.contains("safetensors") || s.contains("unexpected end")
    }

    /// Removes a model's cached files so the next attempt re-downloads from scratch
    /// instead of choking on the same broken file. Clears the app's model cache
    /// (`~/Library/Caches/models/{org}/{model}`, where `ClipmunkModelDownloader`
    /// writes — including any `.part`) and, for good measure, the legacy
    /// HuggingFace hub cache the old downloader used.
    nonisolated static func purgeModelCache(_ modelID: String) {
        let fm = FileManager.default

        // App cache (current downloader).
        var appDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)
        for part in modelID.split(separator: "/") {
            appDir = appDir.appendingPathComponent(String(part))
        }
        try? fm.removeItem(at: appDir)

        // Legacy HuggingFace hub cache (pre-ClipmunkModelDownloader).
        let dir = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let base = ProcessInfo.processInfo.environment["HF_HOME"].map { URL(fileURLWithPath: $0) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface")
        try? fm.removeItem(at: base.appendingPathComponent("hub").appendingPathComponent(dir))
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
            // package. 4096 covers the trimmed inline output (~2k tokens for 6
            // clips) with >2x headroom; the repetition penalty stops runaway loops.
            maxTokens: includeCaptions ? 4096 : s.maxTokens,
            temperature: Self.effectiveTemperature(s.temperature),
            topP: s.topP,
            topK: s.topK,
            minP: s.minP,
            repetitionPenalty: s.repetitionPenalty)
        // Bounded, 8-bit KV cache: fits a long transcript in memory and is the
        // proven-reliable config. (4-bit + quantizedKVStart on a rotating cache
        // threw KVCacheError intermittently for no measured memory win.)
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

        let userPrompt = "Video transcript (with timestamps):\n\n\(transcript)\n\nReturn the clips JSON."

        Self.log("findMoments: transcript \(transcript.count) chars, captions=\(includeCaptions)")
        var raw = ""
        // Split prefill (time to first token, ~fixed by transcript length) from
        // generation (scales with output) and log tok/s — a clip-count-independent
        // speed signal for the optimization loop. Token count approximated as
        // chars/4 (good enough for run-to-run comparison).
        let genStart = Date()
        var firstTokenAt: Date?
        for try await chunk in session.streamResponse(to: userPrompt) {
            if firstTokenAt == nil { firstTokenAt = Date() }
            raw += chunk
        }
        let end = Date()
        let prefillS = (firstTokenAt ?? end).timeIntervalSince(genStart)
        let genS = max(0.001, end.timeIntervalSince(firstTokenAt ?? genStart))
        let tokS = (Double(raw.count) / 4.0) / genS
        Self.log(String(format: "findMoments timing: prefill %.1fs, gen %.1fs, ~%.0f tok/s, %d chars",
                        prefillS, genS, tokS, raw.count))
        Self.log("findMoments raw output (\(raw.count) chars):\n\(raw)")

        let clips = MomentJSONParser.parse(raw)
        Self.log("findMoments: parsed \(clips.count) clip(s) after validation")
        guard !clips.isEmpty else { throw MomentFinderError.noClips }
        return clips
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[clipmunk/director] \(message)\n".utf8))
    }

    /// DEBUG-only decode-temperature override for closed-loop sampling A/B
    /// (e.g. CLIPMUNK_TEMP=0.5). Returns the profile's temperature otherwise.
    nonisolated static func effectiveTemperature(_ fallback: Float) -> Float {
        #if DEBUG
        if let t = ProcessInfo.processInfo.environment["CLIPMUNK_TEMP"], let v = Float(t) { return v }
        #endif
        return fallback
    }

    /// DEBUG-only Director-model override for closed-loop A/B of model sizes
    /// (e.g. CLIPMUNK_DIRECTOR_MODEL=mlx-community/Qwen3.5-4B-MLX-4bit). Returns the
    /// profile's model in Release and when unset. Same Qwen VLM loader path applies.
    nonisolated static func effectiveModelID(_ fallback: String) -> String {
        #if DEBUG
        if let o = ProcessInfo.processInfo.environment["CLIPMUNK_DIRECTOR_MODEL"], !o.isEmpty {
            log("director model overridden via env → \(o)")
            return o
        }
        #endif
        return fallback
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

    /// Moment-finder prompt (moments only, no captions — the clip-watcher path).
    static let systemPrompt = """
    You are an expert short-form video editor (TikTok, Reels, YouTube Shorts). I \
    give you the transcript of a long video, with timestamps. Your job: find the \
    BEST moments to cut into vertical clips that stand on their own and hook in the \
    first 2 seconds.

    Rules:
    - Each clip is 15 to 50 seconds.
    - Pick moments with a hook, a payoff, a complete idea or a memorable line. \
    NEVER cut mid-thought.
    - Return ONLY valid JSON, no text around it, in this shape:
    {"clips":[{"start":"MM:SS","end":"MM:SS","why":"why it's viral","hook":"the clip's first line that stops the scroll","overlay":"VERY short text (3-6 words) to superimpose on screen","score":8}]}
    - "overlay" is a very short, punchy hook in the video's language, meant to show large over the video for the first few seconds.
    - "score": integer 1-10 of how viral it is (strong hook, emotional peak, payoff/complete idea). 10 = essential.
    - Between 3 and 6 clips, ranked best to worst.
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
        // Output-language directive. The prompt is in English, so English is the
        // natural default; naming the target language (by endonym) makes any other
        // choice reliable too — a Spanish prompt used to leak Spanish output.
        let name = Self.languageName(language)
        let languageRule = name.isEmpty
            ? "OUTPUT LANGUAGE: detect the language spoken in the TRANSCRIPT and write EVERYTHING (why, hook, overlay, captions and hashtags) in that same language."
            : "OUTPUT LANGUAGE: write EVERYTHING (why, hook, overlay, captions and hashtags) in \(name), no matter what language is spoken in the video. Every single word of the output must be in \(name)."

        let style = styleExamples.trimmed
        let styleRule = style.isEmpty ? "" : """

        Creator's voice — match this style (tone, rhythm, emojis, formatting):
        \(style)
        """

        return """
        You are an expert short-form video editor (TikTok, Reels, YouTube Shorts). \
        I give you the transcript of a long video, with timestamps. Your job: find \
        the BEST moments to cut into vertical clips that hook in the first 2 seconds, \
        AND for each clip write the full publishing package for all 3 platforms.

        Rules:
        - Each clip is 15 to 50 seconds. One complete idea, never cut mid-thought.
        - ALWAYS return between 3 and 6 clips (minimum 3), ranked best to worst; never an empty array.
        - Each clip's "hook" must be UNIQUE: do not repeat the same hook across clips.
        - "score": integer 1-10 (strong hook, emotional peak, payoff/complete idea). 10 = essential. Use the full range; don't give every clip the same score.
        - \(languageRule)
        - Hashtags: quoted JSON strings, NO '#', NO spaces and NO punctuation — ONE single token per hashtag (CamelCase for multiple words, e.g. "AtlantaRealEstate", never "atlanta real estate"). Each unique, in the output language. Counts: TikTok 3, Instagram 6-8, YouTube 3-5.
        - Return ONLY valid JSON, no text around it, in this EXACT shape:
        {"clips":[{
          "start":"MM:SS",
          "end":"MM:SS",
          "why":"why this moment is viral",
          "hook":"the clip's first line that stops the scroll",
          "overlay":"VERY short text (3-6 words) to superimpose on screen",
          "score":8,
          "captions":{
            "tiktok":{"hook":"first line that stops the scroll, max 90 characters","description":"short, punchy caption","hashtags":["tagOne","tagTwo","tagThree"]},
            "instagram":{"hook":"strong first line","description":"1-2 powerful sentences with storytelling and a call to action","hashtags":["tagOne","tagTwo","tagThree","tagFour","tagFive","tagSix"]},
            "youtube":{"hook":"concise, searchable title, 40-60 characters","description":"keyword-rich description for search","hashtags":["tagOne","tagTwo","tagThree"]}
          }
        }]}
        - Don't invent FACTS that aren't in the transcript (names, prices, numbers): every fact must come from that time range. Generic calls to action ("Save this", "Follow for more") are allowed. Each clip's hook must be unique across clips.\(styleRule)
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
