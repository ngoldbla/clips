# Clipmunk: lean 4-engine model lineup + faceless TTS — design

**Status:** Phases 1–3 shipped (PRs #4–#6, merged to `main`). Phases 4–5 de-risked against
the actual `speech-swift` source on 2026-06-07; ready to plan. See §14 for the locked
Phases 4–5 decisions + verified integration facts.
**Date:** 2026-06-07 (rev. 2026-06-07 — Phases 4–5 de-risk)
**Branch:** `ngoldbla/clipmunk-lean-lineup-tts`
**Supersedes the model choices in:** PR #4 (4B Director), PR #5 (Marlin vision)

---

## 1. Summary

Collapse Clipmunk's scattered four-model LLM menu down to **one small LLM**, fix the
class of bugs where hardcoded model-name strings drift from actual state, and add two
new on-device speech engines. The end state is **four tiny, purpose-built engines**,
each the single owner of its job, all selected through one data-driven catalog:

| Role | Model | Runtime | Status |
|------|-------|---------|--------|
| **LLM** — find moments + write captions | **Gemma 4 E2B** (`unsloth/gemma-4-E2B-it-UD-MLX-4bit`) | mlx-swift via vendored Gemma4Swift (`.gemma4Text`) | replaces Qwen 4B/9B, Gemma 12B, Gemma E4B |
| **Vision** — visual map | **Marlin-2B** (`junwatu/Marlin-2B-MLX-8bit`) | mlx-swift `VLMModelFactory` | unchanged |
| **STT** — low-memory ASR | **Parakeet TDT** | `speech-swift` (CoreML/ANE) | WhisperKit becomes fallback |
| **TTS** — faceless narration (new) | **Kokoro-82M** | `speech-swift` (CoreML/ANE) | brand-new feature |

This directly resolves the two complaints that started this work:
1. *"References to older models that aren't being used"* — the menu of four LLMs plus
   five unused vendored Gemma variants collapses to one, and a single catalog becomes
   the only source of model names.
2. *"Strange defaults"* — e.g. the processing screen showing *"Gemma 4 12B is scanning"*
   while Qwen 4B is selected, and Settings showing *"large-v3-turbo"* when the code
   actually loads `large-v3`. Both are stale strings; the catalog kills the class.

## 2. Goals / non-goals

**Goals**
- One LLM (Gemma 4 E2B) for moment-finding **and** inline caption writing.
- A single source of truth (`ModelCatalog`) for every model id, display name, and the
  status/Settings/download strings that read from it.
- Parakeet STT as the default on memory-constrained Macs, WhisperKit as a guaranteed
  fallback (and the path for non-English audio).
- A new **faceless-narration TTS** feature: Kokoro reads the AI script, the synthesized
  voice **replaces** the clip's audio, and the animated captions re-sync to it.
- An A/B validation pass quantifying E2B vs the outgoing default, on the canonical test
  case, before E2B ships as the default.
- No regressions: every new/risky engine has a fallback so a run can never hard-fail.

**Non-goals**
- Multilingual TTS authoring UI beyond a voice picker (Kokoro's languages are exposed,
  but the feature targets English faceless shorts first).
- Keeping any of the removed LLMs selectable. They are deleted, with a migration for
  users who had one persisted.
- Re-architecting the vision pass (Marlin) beyond moving its strings into the catalog.

## 3. Architecture: the `ModelCatalog` (single source of truth)

**Problem it solves.** Model names today are string literals scattered across
`AppSettings`, `ChatModelProfile`, `ModelManager`, `SettingsView`, `ModelDownloadView`,
`ProcessingView`, `VisualMapper`, `TranscriptionService`, plus README/comments. When a
default changes, the strings rot — that is the entire bug class behind the screenshots.

**Shape.** A new `Clipmunk/Services/ModelCatalog.swift` describing each engine as data:

```swift
struct ModelDescriptor: Sendable {
    let role: ModelRole            // .director, .vision, .stt, .tts
    let hfRepoID: String           // canonical HuggingFace id
    let displayName: String        // the ONE place a user-facing name lives
    let loader: LoaderKind         // .gemma4Text, .vlm, .speechSwiftASR, .speechSwiftTTS, .whisperKit
    let estPeakRAMGB: Double        // for MemoryPolicy + the download screen
}
enum ModelCatalog {
    static let director: ModelDescriptor   // Gemma 4 E2B (+ fallback id, see §4)
    static let vision:   ModelDescriptor   // Marlin-2B
    static let stt:      ModelDescriptor   // Parakeet
    static let sttFallback: ModelDescriptor// WhisperKit large-v3
    static let tts:      ModelDescriptor   // Kokoro-82M
}
```

Every view that currently hardcodes a name reads `ModelCatalog.<role>.displayName` (or,
for the Director status line, the *actually-loaded* descriptor). After this change a
stale model name in the UI is structurally impossible.

## 4. Engine A — Gemma 4 E2B (the only LLM)

**Job.** Read the (optionally vision-augmented) transcript, pick viral moments, and
write the three-platform captions inline in one pass. This is today's "Director +
inline captions" path, now with a single fixed model.

**Model.** Gemma 4 E2B — gemma4-family, ~2.3B effective params, **128K context** (so no
transcript-chunking is ever needed), ~1 GB on disk, ~0.25–1.5 GB peak. Text-only use
through the vendored Gemma4Swift `.gemma4Text` registration, exactly how Gemma 4 12B
loads today.

**Variant selection — real dual-track work, the winner ships (prefer unsloth).** There are
two distributions of E2B:
- **`mlx-community/gemma-4-e2b-it-4bit`** — standard MLX 4-bit; the vendored
  `Gemma4Pipeline.Model.e2b4bit` already enumerates it. This is the **known-good baseline:
  the goal is to get it loading and producing correct moment JSON + inline captions
  perfectly.** It is the model that *must* work.
- **`unsloth/gemma-4-E2B-it-UD-MLX-4bit`** — Unsloth-Dynamic mixed-bit quant; documented as
  *not* loading through standard mlx-vlm. We **empirically determine whether it loads and
  runs correctly** through our `.gemma4Text` path (or the multimodal `Gemma4Engine` path,
  driven text-only — relevant because today E4B only loads multimodally, so the E-series
  text-only registration is itself unproven).

**Outcome rule:** if the unsloth UD variant loads *and* passes the same correctness bar as
the baseline (valid JSON, inline captions parse, runs on 16 GB), **ship unsloth**;
otherwise ship the standard 4-bit. The `ModelCatalog.director.hfRepoID` is the single line
that records the winner. Both are validated; we keep the better-and-working one.

**Sampling.** Start from the Gemma 12B profile's JSON-safe config (temp 0.35, repetition
penalty 1.1, bounded tokens). E2B is smaller, so the salvage parser + a bounded retry
stay; if E2B cannot produce valid JSON after N tries, that single job falls back to the
standard-quant E2B (or, last resort, surfaces a clear error) rather than shipping garbage.

**Removed.** `ChatModelProfile.qwen35_9b`, `.qwen35_4b`, `.gemma12B`; the
`CopywriterModel` cases `qwen35_4b/qwen35_9b/gemma12B/gemmaE4B`; the E4B clip-watcher path
(see §7). `CopywriterModel` collapses to a single effective option (kept as a one-case
enum or replaced by a constant) so call sites stay stable.

**Migration.** Old persisted `clipmunk.copywriterModel` rawValues (`qwen`, `qwen4b`,
`gemma12b`, `gemma`) no longer decode; `AppSettings.init` maps any unknown/legacy value to
the single Director. No user is left pointing at a removed model.

## 5. Engine B — Marlin-2B (vision map), unchanged

No behavior change. Only its name/id move into `ModelCatalog.vision`, and the
`SettingsView`/`VisualMapper` strings read from there. The opt-in
`visionAwareMomentFinding` flag, windowing, and free-after-use lifecycle are untouched.

## 6. Engine C — Parakeet STT (low-memory ASR) via `speech-swift`

**Why.** WhisperKit large-v3 is ~2–3 GB CoreML and contends with the Director for RAM on
16 GB (PR #4 had to free it before the Director loads). Parakeet TDT via `speech-swift`
runs on the ANE at a far smaller footprint, removing that contention.

**Approach.** Add the `soniqo/speech-swift` SwiftPM package (declares macOS 15.0 / Swift
tools 5.10 — both satisfied by Clipmunk's macOS 15 / Swift 6 target). **Confirm its license
before shipping** (not verified in de-risk; the package also vends a `SpeechCore.xcframework`
binary). Introduce an `ASREngine` protocol so the transcription surface is engine-agnostic:

```swift
protocol ASREngine {
    func transcribe(samples16kMono: [Float], languageHint: String?) async throws -> Transcript
    func unload()
}
struct WhisperKitEngine: ASREngine { /* today's code, moved behind the protocol */ }
struct ParakeetEngine:  ASREngine { /* speech-swift CoreML */ }
```

`TranscriptionService.transcript(for:languageHint:)` keeps its **exact** public signature
and `Transcript { segments: [TranscriptSegment { words: [WordStamp] }] }` output — callers
(`WorkspaceModel`) don't move. Internally it picks the engine:
- Sidecar `.srt`/`.vtt` and YouTube CC paths win first, unchanged.
- On-device: **Parakeet** when `MemoryPolicy.isConstrained` **and** language is English/
  unset; otherwise **WhisperKit** (non-English, or 24 GB+ where accuracy is free).
- **Hard fallback:** any Parakeet load/inference failure → WhisperKit. The app
  cannot lose the ability to transcribe.

**Word timestamps (verified against `speech-swift` source, 2026-06-07).** Neither Parakeet
API returns per-word or per-token timings: `TranscriptionResult`/`WordConfidence`
(`AudioCommon`) carry only `text` + `confidence`, and the streaming `PartialTranscript`
exposes only `{text, isFinal, confidence, eouDetected, segmentIndex}` (utterance boundaries,
not word times). The TDT decoder computes per-token durations but discards them. **So
proportional synthesis is the only path here, not a fallback** (decision, §14). `ParakeetEngine`
uses the **streaming** API and emits one `TranscriptSegment` per utterance
(`segmentIndex`/`eouDetected`) with `words: []`; the existing
`Transcript.synthesizeWords(text:start:end:)` (the SRT-sidecar path) fills word stamps
proportionally. Per-utterance segmentation bounds the drift proportional timing incurs over
long un-anchored spans. Real word-level timing remains available on the WhisperKit path
(non-English / 24 GB+). Recovering true Parakeet word timing would require the separate
Qwen3ASR ForcedAligner — an extra model off the lean lineup; out of scope for v1.

**Model + artifacts.** Default model `aufklarer/Parakeet-TDT-v3-CoreML-INT8-30s` (CoreML/ANE,
INT8); `ParakeetASRModel.fromPretrained()` downloads it from HuggingFace on first run into
`~/Library/Caches/qwen3-speech/` (`offlineMode: true` only works once cached). Budget
first-run download + progress UX. Parakeet is CoreML/ANE — it does **not** need the Kokoro
`mlx.metallib` step (§10).

**Audio.** Reuse `MediaExtractor` to get audio, then **downmix to mono + resample to 16 kHz +
convert to Float32** (`ParakeetConfig.sampleRate == 16000`; `transcribeAudio(_:sampleRate:language:)`
wants `[Float]`). Source audio off `AVAsset` is typically 44.1/48 kHz stereo — do the
rate + channel conversion in one `AVAudioConverter` pass (output `pcmFormatFloat32`,
`sampleRate: 16000`, `channelCount: 1`), reading `floatChannelData[0]` into `[Float]`.
**Memory:** `MemoryPolicy.shouldFreeWhisperAfterTranscribe` generalizes to
`shouldFreeASRAfterTranscribe`; Parakeet (~hundreds of MB) need not be force-freed.

**Caveat (English-first routing).** The TDT-v3 model is multilingual-capable (European
languages), but v1 routes **English/unset → Parakeet** (when constrained) and **non-English
→ WhisperKit** automatically, preserving today's multilingual accuracy. Routing signal:
`Transcript.contentLanguage` (already computed via `NLLanguageRecognizer`).

## 7. Engine D — Kokoro-82M TTS: faceless narration (new feature)

**What the user gets.** A per-clip, opt-in (off by default, like vision/YouTube) toggle
"Faceless voiceover" plus a voice picker. When on, Kokoro reads the clip's **script**, the
synthesized voice **replaces** the clip's original audio, and the animated word-captions
re-sync to the new narration — turning a cut into a clean B-roll/faceless short.

**Model.** Kokoro-82M via `speech-swift` (`import KokoroTTS`, CoreML/ANE), 24 kHz output,
~200 MB peak. Default model `aufklarer/Kokoro-82M-CoreML` (downloaded on first run). ~54 voices
across 10 languages — **not** a committed Swift enum; they load at runtime from `voices/*.json`
in the downloaded model bundle. The voice picker therefore **enumerates the actual installed
voices at runtime** (decision §14), grouped by language prefix (`af_`/`am_` American,
`bf_`/`bm_` British, `jf_`/`jm_` Japanese, `zf_`/`zm_` Chinese, …), defaulting to `af_heart`.
G2P is handled inside the package. **Build note:** Kokoro runs MLX GPU kernels and needs the
`mlx.metallib` build+bundle step (§10) or it crashes at first GPU op.

**Source text.** The clip's narration text = the Director-written script. Default to the
clip's primary caption/long-form text (`PostVariant`/`candidate.hook` + caption body);
exact field chosen in the plan from `CaptionScript`/`PostVariant`. Kept short to keep
narration near clip length.

**Pipeline (new stage, at render time).** Slots into the existing single composition pass
(`VerticalReframer.process` / `VideoOverlayRenderer.render`), which already muxes
video + audio + caption layer:
1. **Synthesize.** `KokoroTTSModel.synthesize(text:voice:language:speed:) throws -> [Float]`
   (synchronous; 24 kHz mono Float32), after loading once via `try await
   KokoroTTSModel.fromPretrained()`. Returns **audio only — no timing data** (verified: the
   model computes a `predDur` phoneme-duration tensor internally but never surfaces it). Call
   `synthesize(voice:)` directly, **not** the protocol `generate(...)`, which hardwires the
   default voice and ignores the picker.
2. **Re-sync captions.** Measure `narrationLen = samples.count / 24000.0`, derive word stamps
   with the existing `Transcript.synthesizeWords(text:start:0,end:narrationLen)`
   (character-weighted proportional spread over the *known, clean* script — the accurate case
   for proportional timing), and feed them to `CaptionScript.build(...)`. Captions track the
   spoken voice. Plumbing unchanged; only the *source* of word stamps changes from
   "engine timings" to "proportional over the measured narration length."
3. **Reconcile duration.** Clip length := narration length. Default reconciliation:
   trim trailing TTS silence; if video < narration, **freeze-hold the last frame** (or
   slow to fit — plan picks one); if video > narration, trim video. (This is the one
   genuinely new design choice; default = freeze-hold, simplest and artifact-free.)
4. **Compose & export.** Same composition, but the audio track is the TTS samples instead
   of the original; captions + optional hook burned as today.

**Data model.** Add to `ShortClip`: `narrationEnabled: Bool` (default from a new
`AppSettings.ttsEnabled`, off) and `narrationVoiceID: String`. Persist both in
`StoredClip` so a reopened job re-renders identically. `isRendered`/`makeRenderedFile`
gain the narration branch.

**Fallback.** If Kokoro fails to load/synthesize, the clip renders with its **original
audio** and transcript-timed captions (i.e. today's behavior) and a non-fatal notice.

## 8. A/B validation harness (gates the E2B default)

A developer probe + `scripts/` runner (mirroring the `Probe`/`MarlinProbe` pattern and
PR #5's closed-loop A/B). It drives the **canonical Marietta test case**
(`.context/testcase/`) through moment-finding twice — **candidate (E2B)** vs **reference
(the outgoing default)** — selected by an env override (`CLIPMUNK_DIRECTOR_MODEL`, an
extension of the existing DEBUG env pattern). It reports: JSON-valid rate, moment count &
overlap with the reference picks, caption quality (LLM-judge), prefill/gen latency, and
peak RAM. Output is a committed markdown report, exactly like PR #5's A/B results, and is
the evidence for shipping E2B as the default (vs. falling back to standard-quant E2B).

## 9. Cleanup sweep (the screenshots)

All read against `ModelCatalog` or the actually-loaded descriptor:
- **Status-text bug** (`ShortsProgressView`/`MomentFinderService`): the Director's
  `profile`/displayName initializes from the selected model, never a hardcoded
  `.gemma12B`. *"X is scanning the transcript"* shows the real model.
- **`SettingsView:77`** `"WhisperKit · large-v3-turbo"` → dynamic STT name
  ("Parakeet" or "WhisperKit · large-v3") from the catalog.
- **Stale comments/docs:** `AppSettings:190`, `MomentFinderService:11`,
  `ClipCandidate:3`, `ShortClip:4`, `MemoryPolicy` header, README badges/diagram/table,
  `project.yml` marlin-probe "developer-only" note. All updated to the new lineup.
- **Dead vendored variants** (E2B-unused/E4B/31B/26B-A4B) stay in the vendor package but
  are not exposed; only the Director descriptor references E2B.

## 10. Removals & migration summary

- **Code removed:** `ChatModelProfile.qwen35_9b/.qwen35_4b/.gemma12B`; the multi-case
  `CopywriterModel`; the E4B clip-watcher path in `WorkspaceModel`/`ModelManager`/
  `GemmaService` (single-clip "Caption a short" now runs through the E2B Director on
  transcript + optional Marlin).
- **UserDefaults migration:** legacy `clipmunk.copywriterModel` values → single Director.
- **project.yml:** add `speech-swift` pinned **`exact: "0.0.20"`** (it ships no upstream
  `Package.resolved`, so freeze it for reproducible CI). Import only `ParakeetASR`/
  `ParakeetStreamingASR`, `KokoroTTS`, `AudioCommon`. **Bump `WhisperKit` `0.9.0` → `1.0.0`**
  — `speech-swift` requires `WhisperKit >= 1.0.0` and the ranges are otherwise disjoint (hard
  `swift package resolve` failure, even though we never link their benchmark). WhisperKit 1.0
  is a SemVer-major: audit `TranscriptionService`'s WhisperKit call sites (`WhisperKitConfig`,
  `download(variant:)`, `transcribe`, the word-timestamp struct). WhisperKit 1.0 also **drops
  its `swift-transformers` dep**, removing the old transitive `<1.2.0` cap, so swift-transformers
  floats upward — re-verify Gemma4Swift/mlx-swift-lm compile, add a deliberate cap if it drifts.
  **Metal build step (Kokoro only):** run `speech-swift`'s `scripts/build_mlx_metallib.sh`
  (needs the Metal Toolchain + native ARM Homebrew) after package resolve, and **copy
  `mlx.metallib` into `Clipmunk.app` next to the binary before signing/notarization** — else
  Kokoro crashes at first GPU op and the notarized DMG ships broken. Add a build verification
  that fails if `mlx.metallib` is missing from the bundle. Parakeet (CoreML/ANE) needs none of this.

## 11. Build sequence (one PR, reviewable phased commits)

1. **Catalog + cleanup + status-bug fix.** Fixes every screenshot with zero model risk.
2. **Wire E2B as the sole Director.** Get standard `mlx-community/gemma-4-e2b-it-4bit`
   loading + producing correct moment JSON / inline captions perfectly; then validate the
   unsloth UD variant and set `ModelCatalog.director` to whichever works (prefer unsloth).
   `CopywriterModel` collapse + migration + drop E4B clip-watcher.
3. **A/B harness;** run on the test case; report E2B vs the outgoing default.
4. **Parakeet STT** via `speech-swift` (`ASREngine`, routing, WhisperKit fallback, memory).
5. **Kokoro TTS** faceless narration (synthesis, caption re-sync, duration reconcile,
   Settings voice picker + per-clip toggle, `StoredClip` persistence).
6. **Docs + end-to-end verification on 16 GB.**

## 12. Testing & verification

- E2B: loads on 16 GB; valid moment JSON on the test case; inline captions parse.
- Parakeet: transcribes the test case; word timings drive captions; English path uses
  Parakeet, a forced non-English clip uses WhisperKit; induced Parakeet failure falls
  back cleanly.
- Kokoro: a clip with narration on plays the synth voice, captions track it, duration
  reconciled with no black frames; narration-off clips are byte-for-byte today's output.
- Memory: full pipeline (Parakeet → optional Marlin → E2B → optional Kokoro) stays within
  RAM on a 16 GB Mac with ~0 swap (the project's standing bar).
- Migration: a profile with a legacy `copywriterModel` opens without error on the Director.

## 13. Open risks

- **E2B loadability** (Engine A) — the standard 4-bit must work perfectly (baseline); the
  unsloth UD variant is validated alongside and shipped only if it loads + passes the same
  bar. Sub-risk: the `.gemma4Text` text-only path may not support the E-series decoder
  (E4B loads multimodally today), handled by the multimodal-engine-driven-text-only path.
- **Parakeet word timestamps** — RESOLVED (2026-06-07): `speech-swift` exposes none;
  proportional synthesis, per-utterance segmented, is the committed path (§6, §14).
- **`speech-swift` build integration** — RESOLVED/SCOPED: pin `exact: "0.0.20"`; **WhisperKit
  must bump to `1.0.0`** (resolve-blocker); Kokoro needs the `mlx.metallib` build + bundle-copy
  step (Metal Toolchain + ARM Homebrew on CI); Parakeet artifacts download to
  `~/Library/Caches/qwen3-speech/` on first run — budget first-run latency/progress UX (§6, §10).
- **TTS duration reconciliation** — freeze-hold vs slow-to-fit is a quality call; default
  freeze-hold, revisit if it looks bad on real clips.
- **E2B quality floor** — below PR #4's 4B finding; the A/B harness is the honest gate,
  with standard-quant E2B / a larger fallback one catalog line away if it underperforms.

## 14. Phases 4–5 de-risk decisions & verified integration facts (2026-06-07)

This section supersedes any conflicting timing/dependency assumptions in §§6–7,10. All facts
below were verified against the actual `soniqo/speech-swift` source (adversarially, twice).

**Locked decisions (owner Dylan, 2026-06-07):**
1. **Parakeet captions = proportional, segmented per-utterance.** On 16 GB (the default
   target) STT routes to Parakeet, which gives no word timings; we accept proportional word
   timing (segmented per utterance to bound drift) for the memory win. WhisperKit (real
   timings) remains for non-English / 24 GB+.
2. **WhisperKit bumps `0.9.0` → `1.0.0`** to satisfy `speech-swift`; adapt
   `TranscriptionService`'s WhisperKit call sites.
3. **Kokoro voice picker enumerates installed voices at runtime** from the model bundle's
   `voices/*.json` (no hardcoded list), grouped by language prefix, default `af_heart`.

**Verified `speech-swift` facts (pin `exact: "0.0.20"`, internal package name `Qwen3Speech`):**

| Item | Value |
|---|---|
| Modules to import | `ParakeetASR` / `ParakeetStreamingASR`, `KokoroTTS`, `AudioCommon` |
| Parakeet model | `aufklarer/Parakeet-TDT-v3-CoreML-INT8-30s` (CoreML/ANE) |
| Parakeet input | `[Float]` PCM, **16 kHz mono Float32** (`transcribeAudio(_:sampleRate:language:)`) |
| Parakeet result | `TranscriptionResult { text, language?, confidence, words:[WordConfidence{word,confidence}] }` — **no times**; streaming `PartialTranscript { text, isFinal, confidence, eouDetected, segmentIndex }` |
| Kokoro load / synth | `try await KokoroTTSModel.fromPretrained()`; `synthesize(text:voice:language:speed:) throws -> [Float]` (sync, **24 kHz mono**, audio only) |
| Kokoro model / default voice | `aufklarer/Kokoro-82M-CoreML` / `af_heart`. Do **not** use protocol `generate(...)` (hardwires voice). |
| Artifact cache | `~/Library/Caches/qwen3-speech/` (HuggingFace download on first run) |
| Metal build (Kokoro only) | `scripts/build_mlx_metallib.sh` → `mlx.metallib` copied into `Clipmunk.app` beside the binary **before signing**; needs Metal Toolchain + ARM Homebrew. Parakeet needs none. |

**Hard gates before the build goes green / ships:**
- `project.yml`: WhisperKit → `from: "1.0.0"`; add `speech-swift` `exact: "0.0.20"`.
  Re-check `swift package resolve` succeeds (it fails today).
- After the bump, compile `TranscriptionService.swift` first; adapt the WhisperKit 1.0 API.
- Confirm `swift-transformers` (now uncapped) still lets Gemma4Swift/mlx-swift-lm compile;
  add an explicit cap if it floats too high.
- Wire + verify the `mlx.metallib` bundle-copy before any Kokoro run and before DMG signing.

## 15. As-built status (Phases 4–5 SHIPPED, 2026-06-08)

§6 (Parakeet) and §7 (Kokoro) are implemented and verified end-to-end on a **16 GB** M-series
Mac (the constrained default path). The app, `shorts-probe` and `narration-probe` build green;
a forced-Parakeet `shorts-probe` run produced `SHORTS_OK`, and `narration-probe` produced valid
faceless clips for both the trim and freeze-hold duration cases.

As-built deviations from the plan (all deliberate, verified against the resolved `speech-swift`
`0.0.20` source — pinned in `project.yml` via `exactVersion: "0.0.20"`):

- **Parakeet model = `aufklarer/Parakeet-EOU-120M-CoreML-INT8`** (the streaming EOU model that
  `ParakeetStreamingASRModel.fromPretrained()` actually downloads), *not* `Parakeet-TDT-v3`.
  `ModelCatalog.stt` and the README reflect this.
- **EOU under-segments monologue audio** (it segments on conversational turns, returning one
  long, punctuation-less utterance). `ParakeetEngine` re-chunks such output into ~6 s word
  groups so proportional caption drift stays bounded per segment (decision §14.1's intent).
- **`ASREngine.transcribe` takes `audioURL`** (extracted `.m4a`); routing + the WhisperKit hard
  fallback live entirely inside `TranscriptionService`; a `CLIPMUNK_STT` DEBUG env override
  forces an engine for A/B.
- **Narration is a render pre-stage** via `NarrationComposer` (audio swap + freeze-hold/trim);
  captions re-sync proportionally over the narration length; any failure falls back to the
  original-audio path.
- **Kokoro's E2E graph is fixed at 128 phonemes (~5 s)**, so `NarrationService` chunks long
  scripts (sentence/word packing) and stitches the pieces with a short silence gap — a full
  script is narrated, not truncated.
- **No `mlx.metallib` step needed (Task 5.8 skipped).** A real `narration-probe --selftest`
  Kokoro synthesize succeeds with the existing mlx-swift build — no "default metallib" failure.
- **`speech-swift` license = Apache 2.0** — compatible with shipping in a signed/notarized DMG.
