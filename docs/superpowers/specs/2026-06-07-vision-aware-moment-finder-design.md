# Vision-aware moment-finder (Marlin-2B-MLX) — design

**Date:** 2026-06-07
**Branch:** `ngoldbla/marlin-2b-mlx-port`
**Status:** approved design; executing.

## Goal

Give Clipmunk's moment-finder ("the Director") **sight**. Today the Director is a
text-only LLM that picks viral clips from a `[MM:SS] speech` transcript — it is
blind to what is on screen (maps, B-roll, demos, charts, on-screen text). Add a
**pre-Director perception pass** that watches the video and produces a
timestamped "WHAT happens WHEN" track, merged into the transcript the Director
already reads. The Director keeps all editorial judgment; it just gains vision.

The perception model is **Marlin-2B** (`junwatu/Marlin-2B-MLX-8bit`), a
video VLM purpose-built for **dense captioning + temporal grounding**.

Role decision (user): **A — perception layer feeding the text Director**, with
**C — `find()` boundary refinement** as a later enhancement. Not B (Marlin does
not replace the Director).

## Key finding that reshaped the effort

The original plan assumed a multi-week from-scratch MLX port. **It isn't needed.**
Marlin is a Qwen3.5-2B fine-tune:

- `config.json`: `model_type: "qwen3_5"`, `architectures: ["MarlinForConditionalGeneration"]`,
  hybrid linear-attention/SSM text backbone (`layer_types` 3×`linear_attention` :
  1×`full_attention`, `linear_conv_kernel_dim`, `mamba_ssm_dtype`), Qwen3-VL
  vision tower (`patch_size 16`, `temporal_patch_size 2`, M-RoPE interleaved
  `mrope_section [11,11,10]`), `image_token_id 248056`.
- `processor_config.json`: `processor_class: "Qwen3VLProcessor"`.

`mlx-swift-lm` (pinned commit `a47894a`, 2026-06-04) **already implements all of
this**: `Qwen35.swift` ports mlx-vlm's `qwen3_5` including `GatedDeltaNet`
(the SSM/linear-attention layers), `MambaCache`, the `(layerIdx+1) %
fullAttentionInterval` hybrid dispatch, and the Qwen3-VL vision tower; the
registry maps `qwen3_5` → `Qwen35` and `Qwen3VLProcessor` → its processor. The
Clipmunk app **already loads a `qwen3_5` model today** (the Qwen3.5-4B Director),
so the SSM inference path is already proven here.

**Therefore the work is:** seed the weights → load Marlin through the *existing*
`VLMModelFactory` → replicate `modeling_marlin.py`'s thin prompt-templating +
timestamp-parsing in Swift → feed chunked video → settle timestamp fidelity →
integrate as the perception layer. No new model architecture code.

## The one real risk: timestamp fidelity (WHEN)

The whole value is accurate timestamps. Marlin's card warns that *pure-MLX*
inference can compress timestamps (mlx-vlm's `qwen3_5` path mishandled
`mm_token_type_ids`/M-RoPE). The notarized Swift app cannot bundle PyTorch, so we
must get accurate timestamps from pure-Swift MLX. Mitigations (no Python oracle,
per user):

- **Span fingerprinting:** assert emitted spans are monotonic, within the chunk
  window, advancing, and plausibly long — the "compressed" failure has an obvious
  signature (spans collapsing to ~0 or clustering).
- **`find()` spot check:** ask Marlin when an obvious on-screen event occurs and
  confirm the span lands in the right region (2-min sanity test).
- If compressed, investigate the Swift `Qwen35`/`Qwen3VL` M-RoPE temporal
  position-id computation (the known culprit) and fix upstream-style.

## Chunking is a correctness requirement, not just speed

Marlin trains at 2 fps with `max_frames` ≈ 240 (≈120 s). The Swift Qwen3-VL
sampler is hardwired to 2 fps over the *entire* input, so an 11-min video would
exceed the budget and rescale time → corrupt timestamps. So the perception pass
**splits the video into ≤~120 s windows**, runs Marlin per window, and **offsets
each window's spans to absolute video time**. The sample video `J6v61QQqsC8`
(≈11:09) → ~6 windows.

## Components

- **`MarlinProbe/main.swift`** (dev tool, done): loads Marlin via
  `VLMModelFactory`, runs caption/find on an optionally sub-ranged clip, prints
  raw spans + timing + memory. The make-or-break instrument.
- **`VisualMapper.swift`** (new service, app): owns the Marlin `ModelContainer`
  (`prepareIfNeeded`/`unload`, mirroring `MomentFinderService`); chunks the video
  (`AVAssetExportSession` sub-ranges), runs caption mode per chunk, parses
  `Scene:` + `<start - end> desc` into events, offsets to absolute time.
- **`VisualEvent` / `VisualTimeline`** (`{start,end,text}` seconds): value types.
- **Merge** (pure fn): interleaves `[MM:SS] speech` and `[t1-t2] VISUAL: event`
  into the augmented transcript injected at `MomentFinderService.swift:188`.

## Pipeline & memory (16 GB M1 floor)

New stage 2.5 in `WorkspaceModel.runShortsPipeline`, after transcription, before
the Director, respecting one-large-model-at-a-time on constrained RAM:
free Whisper + copywriter → **load Marlin (~5 GB) → vision pass → free Marlin** →
load Director → `findMoments(augmentedTranscript)`. Marlin (2.66 GB disk) is
smaller than the current Director, so it fits the existing tiering.

## Closed loop (Swift-only, automatable)

- **Flag-gated A/B:** `settings.visionAwareMomentFinding` + DEBUG env
  `CLIPMUNK_VISION_PASS=0|1`, `CLIPMUNK_VISION_FPS`/window knobs. Same video, off
  = baseline, on = augmented.
- **Structured metrics:** `CLIPMUNK_METRICS_OUT=<path>` tees a per-run JSON
  (phase durations, memory, vision-pass stats, moment list + captions) alongside
  the existing stderr logs.
- **Judge:** run the autorun pipeline twice over
  `.context/testcase/J6v61QQqsC8.mp4` (+ `.en.srt` to skip Whisper); the model
  (Claude) judges the two moment lists A/B on hook strength, visual relevance,
  coherence. Quality gate per iteration = augmented wins the judge **and** stays
  within the duration budget (≈ transcription time).

## Testing

TDD the pure functions (caption parser, span parser, merge) against captured
Marlin fixtures. Model load + pipeline wiring validated by probe/autorun runs.

## Build sequence

1. Loadability spike (probe loads Marlin, emits `<start-end>` caption). 
2. Timestamp-fidelity gate (spans plausible, `find()` spot check).
3. `VisualMapper` (chunking + parser, TDD).
4. Merge + flag-gated Director integration.
5. Lifecycle/memory on 16 GB (no swap).
6. Metrics JSON + A/B harness + judge; iterate (each loop measured).

## Results — validated 2026-06-07 (16 GB M1 Pro, sample video J6v61QQqsC8, 11:08)

**Loadability:** Marlin-2B-MLX-8bit loads through the existing `VLMModelFactory`
in ~2.6 s (~2.5 GB resident) — **no new architecture code**. `Qwen35.swift`'s
`GatedDeltaNet`/`MambaCache` SSM layers + Qwen3-VL vision tower run in pure Swift.

**Timestamp fidelity:** NOT compressed — spans advance linearly and stay within
each window (the feared mlx-vlm `qwen3_5` timestamp bug does not reproduce in the
Swift port). Greedy decoding looped the *events*; `repetitionPenalty 1.12` + a
350-token cap fixed it (gen 65 s → ~9 s).

**Tuning:** vision-token attention is ~quadratic and crosses the ~10 GB
`memoryLimit` soft cap on big windows (30 s→27 s, 60 s→98 s, 90 s→330 s+ throttle).
Final config **45 s windows / 448 px / 350 tok / rep 1.12**: ~45 s per window,
peak ~7 GB (no throttle). Full 11-min video = 15 windows, 80 events, **~11.4 min**
vision pass.

**A/B (transcript-only Director vs. vision-augmented), Qwen 3.5 4B Director:**
- Augmented transcript 30 k chars vs 12 k baseline (visual track ≈ tripled context).
- Baseline: 3 moments, generic topic-label overlays.
- Augmented: 6 moments, two hooked on **on-screen-only data the transcript lacks** —
  `Price Range: $450k–$2.5M` and `HOA Fees: $2,700/year` (graphic overlays Marlin
  read), plus the real on-screen `THE #1 QUESTION` graphic. The scene track also
  surfaced school-name graphics, neighborhood map routes, the Civil-War cannon,
  the downtown market, and the outro `TOP 5 NEIGHBORHOODS` thumbnail — none spoken.
- Memory: Director prefill on the larger augmented transcript peaked ~11 GB
  (transient, throttled not swapped) vs ~7.6 GB baseline — the cost of the richer
  context on 16 GB.

**Verdict:** the perception layer delivers accurate, timestamped WHAT-on-screen-WHEN
and measurably improves moment selection. Default OFF (opt-in) given the added time.

**Known follow-up (optimization, not correctness):** the 2 fps sampler is hardwired
in `mlx-swift-lm`'s `Qwen3VL.swift`; total vision time is floored by total frames.
Vendoring that package to expose a lower fps (e.g. 1 fps) would roughly halve the
pass — but Marlin trains at 2 fps, so timestamp calibration must be re-validated if
fps changes.

## Validation artifacts & how to reproduce

- `MarlinProbe/` — `marlin-probe <video> caption|find [--start S --dur D --resize --rep-penalty --max-tokens]`.
- `scripts/vision-ab.sh [video] [director-id]` — runs the pipeline twice
  (baseline vs augmented), captures each Director's moments + dumps the
  augmented transcript to `.context/ab/`.
- DEBUG env: `CLIPMUNK_VISION_PASS=0|1`, `CLIPMUNK_VISION_DUMP=<path>`,
  `CLIPMUNK_VISION_WINDOW/RESIZE/MAXTOK/REP`, `CLIPMUNK_VISION_MODEL`.
