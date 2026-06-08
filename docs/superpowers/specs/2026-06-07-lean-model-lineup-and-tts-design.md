# Clipmunk: lean 4-engine model lineup + faceless TTS — design

**Status:** Draft for review
**Date:** 2026-06-07
**Branch:** `ngoldbla/melbourne`
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

**Approach.** Add the `soniqo/speech-swift` SwiftPM package (Apache-2.0; macOS 15+/Swift
6+, both of which Clipmunk already targets — see `project.yml`). Introduce an `ASREngine`
protocol so the transcription surface is engine-agnostic:

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
- **Hard fallback:** any Parakeet load/inference/timestamp failure → WhisperKit. The app
  cannot lose the ability to transcribe.

**Word timestamps.** `speech-swift` exposes token/sentence timing; if Parakeet TDT word
boundaries aren't directly available, group tokens→words, else fall back to the existing
proportional synthesizer (the same one used for timing-less SRT sidecars). Captions need
word timing; this guarantees they get it.

**Audio.** Reuse `MediaExtractor` to get audio, resample to 16 kHz mono `[Float]`, feed the
engine. **Memory:** `MemoryPolicy.shouldFreeWhisperAfterTranscribe` generalizes to
`shouldFreeASRAfterTranscribe`; Parakeet (~hundreds of MB) need not be force-freed.

**Caveat (English-only path).** Parakeet-int4/TDT is English-strong; non-English source
audio routes to WhisperKit automatically, preserving today's multilingual behavior.

## 7. Engine D — Kokoro-82M TTS: faceless narration (new feature)

**What the user gets.** A per-clip, opt-in (off by default, like vision/YouTube) toggle
"Faceless voiceover" plus a voice picker. When on, Kokoro reads the clip's **script**, the
synthesized voice **replaces** the clip's original audio, and the animated word-captions
re-sync to the new narration — turning a cut into a clean B-roll/faceless short.

**Model.** Kokoro-82M via `speech-swift` (`import KokoroTTS`, CoreML/ANE), 24 kHz output,
~200 MB peak, 32+ voices (EN/JA/ZH). G2P is handled inside the package.

**Source text.** The clip's narration text = the Director-written script. Default to the
clip's primary caption/long-form text (`PostVariant`/`candidate.hook` + caption body);
exact field chosen in the plan from `CaptionScript`/`PostVariant`. Kept short to keep
narration near clip length.

**Pipeline (new stage, at render time).** Slots into the existing single composition pass
(`VerticalReframer.process` / `VideoOverlayRenderer.render`), which already muxes
video + audio + caption layer:
1. **Synthesize.** `KokoroTTS.synthesize(text, voice)` → 24 kHz `[Float]` + per-word (or
   per-token) timings.
2. **Re-sync captions.** Rebuild the clip's `CaptionScript` from the TTS word timings via
   the existing `CaptionScript.build(words:clipStart:0,clipEnd:narrationLen)` — captions
   now track the spoken voice, not the original transcript.
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
- **project.yml:** add `speech-swift`; keep WhisperKit (now fallback). Note `speech-swift`
  may need a Metal-library build step (`make build`) wired into the XcodeGen build.

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
- **Parakeet word timestamps** via `speech-swift` — may need token→word grouping or
  proportional synthesis.
- **`speech-swift` build integration** — Metal library/`make build` step, model artifact
  download location, first-run latency.
- **TTS duration reconciliation** — freeze-hold vs slow-to-fit is a quality call; default
  freeze-hold, revisit if it looks bad on real clips.
- **E2B quality floor** — below PR #4's 4B finding; the A/B harness is the honest gate,
  with standard-quant E2B / a larger fallback one catalog line away if it underperforms.
