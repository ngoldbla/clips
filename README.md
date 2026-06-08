<div align="center">

<img src="assets/clipmunk-mascot.png" alt="Clipmunk logo — a chipmunk cutting a strip of film with scissors" width="200" />

# Clipmunk

**Long videos → ready-to-post shorts for TikTok, Instagram Reels and YouTube Shorts.**
**Found, cut, captioned, reframed and scheduled — fully on your Mac. Open-source.**

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-1d1d1f)
![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)
![Model](https://img.shields.io/badge/Gemma_4_E2B-on--device-4285F4)
![Whisper](https://img.shields.io/badge/WhisperKit-large--v3-00B8D9)

<br />

<sub>Drop a long video → it transcribes, finds the best moments, cuts them, writes the copy, reframes to vertical → review the grid → publish or schedule the whole week.</sub>

</div>

---

## What it does

Clipmunk has two modes:

### 🎬 Make shorts from a long video (the main one)

Drop a podcast, talk, stream or any long recording. Clipmunk transcribes it on-device,
finds the **best 3–6 viral moments**, cuts each one, and writes the **full post copy for
all three platforms** — all in one pass. Horizontal (16:9) footage is **reframed to
vertical 9:16**, tracking the speaker's face. You get a grid of finished shorts you can
play with sound, edit, download, publish, or **schedule one-per-day across the week**.

### ✏️ Caption a short

Already have a short vertical clip? Drop it and Clipmunk **transcribes it and writes the
three platform captions** (Gemma 4 E2B) directly, rendered as editable phone-style previews.

What's different about Clipmunk:

- 🛰️ **Nothing leaves your Mac during processing.** No cloud model, no upload.
  Your video is only sent to a network when you choose to publish it.
- 🧠 **One model does the thinking.** A single on-device LLM reads the whole transcript,
  picks the moments *and* writes every caption in the same pass.
- 🎯 **Tuned per platform.** TikTok gets punchy. Instagram gets storytelling and 20–30
  hashtags. YouTube gets short, search-friendly titles — in the language spoken in the video.
- 📐 **Auto vertical reframe.** On-device face tracking (Vision) turns 16:9 into 9:16,
  panning to keep the speaker centred, with a blurred-background fallback when there's no
  clear face.
- 🗓️ **Schedule the week in one click.** Distribute approved shorts one per day, pick the
  time, and Upload-Post publishes them automatically.
- 🪶 **No Python. No Electron. No embedded runtime.** Just Swift, MLX, AVFoundation, Vision.

## How a long video becomes shorts

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │  YOUR MAC — nothing leaves until you press Publish                    │
  │                                                                       │
  │  drop a long video                                                    │
  │        │                                                              │
  │        ▼                                                              │
  │  ┌──────────────┐   ┌────────────────────┐   ┌───────────────────┐    │
  │  │ WhisperKit   │──►│  Director LLM       │──►│ AVFoundation      │    │
  │  │ large-v3     │   │  Gemma 4 E2B        │   │ cut each clip     │    │
  │  │ transcribe   │   │  finds moments +    │   │ + reframe 9:16    │    │
  │  │ (GPU)        │   │  writes 3 captions  │   │  (Vision tracking)│    │
  │  └──────────────┘   │  in ONE pass        │   │ + hook overlay    │    │
  │                     └────────────────────┘   └───────────────────┘    │
  │                                                       │                │
  │                                                       ▼                │
  │                                              ┌───────────────────┐     │
  │                                              │ grid of shorts:   │     │
  │                                              │ play w/ sound,    │     │
  │                                              │ edit, download,   │     │
  │                                              │ approve           │     │
  │                                              └───────────────────┘     │
  └──────────────────────────────────────────────────────────────────────┘
                                  │  Publish now  /  Schedule the week
                                  ▼
                          ┌─────────────────┐
                          │   Upload-Post   │  TikTok · Instagram · YouTube
                          │       API       │  (now, or scheduled per day)
                          └─────────────────┘
```

Concretely:

1. **Transcribe.** If the video has a `.srt`/`.vtt` sidecar, it's used instantly.
   Otherwise it transcribes on-device: **Parakeet** (CoreML/ANE, ~0.6 GB) on memory-tight
   Macs for English, falling back to **WhisperKit** (`large-v3`) for non-English or when
   there's RAM headroom. The transcript's language is detected from the *text*
   (NaturalLanguage), so captions stay in the spoken language.
2. **Watch, then find the moments + write the copy.** First the **Marlin-2B** vision model
   watches the footage and hands the Director a timestamped "what's on screen, when" track
   (B-roll, on-screen text, scene changes the words alone don't reveal) — this perception
   pass is core to picking good moments, so it always runs. Then the **Director** — an
   on-device LLM — reads that vision-augmented transcript and returns a single JSON: the
   best clips (start/end, why, hook, a short on-screen overlay) **and** the full TikTok /
   Instagram / YouTube caption package for each, in one pass. A tolerant parser strips
   fences/thinking and validates clip durations.
3. **Cut.** AVFoundation cuts each moment to its own file.
4. **Reframe (optional, automatic for horizontal clips).** Vision samples faces across
   the clip; if the speaker is found, an `AVMutableVideoComposition` pans a 9:16 crop to
   follow them (GPU-interpolated transform ramps). No clear face → a blurred-background
   letterbox. A short text **hook** can be burned over the top.
5. **Review.** A grid of phone-style tiles — loop each short, play it with sound, edit the
   captions, download the rendered `.mp4`, or approve it.
6. **Publish or schedule.** Publish now, or **schedule the week**: approved shorts go out
   one per day at a time you choose, via Upload-Post's `scheduled_date`. TikTok lands as a
   draft by default so you can finish in-app.

### The model

One small on-device LLM does all the language work — it finds the moments **and** writes
every platform's captions in the same pass:

| Model | Role | Notes |
|-------|------|-------|
| **Gemma 4 E2B** | Director + inline captions | A ~2.3 B-effective gemma-4 model, ~1 GB on disk. 128 K context, so a full long-video transcript fits in one pass. Runs comfortably on 16 GB alongside the Marlin-2B vision pass (loaded one model at a time). |

It downloads once on first use, then everything runs offline. No model picker, no
per-machine split — the same lean model runs everywhere.

## Requirements

- **Apple Silicon** Mac (M1 or later), **macOS 15+**.
- **Memory:** **16 GB RAM minimum**. The Director (Gemma 4 E2B) and the Marlin-2B vision
  pass (which always runs) load one-at-a-time, so nothing swaps on 16 GB.
- **Disk:** ~**6 GB free** for the on-device models downloaded on first run
  (Gemma 4 E2B ≈ 3.6 GB; the lean Parakeet STT ≈ 0.6 GB, or WhisperKit large-v3 ≈ 1.5 GB),
  plus the Marlin-2B vision model (~2.5 GB, always used) and the optional Kokoro voiceover (~0.3 GB),
  and working space for the videos you process. Models download once from Hugging Face, then
  run offline.

## Install

1. Download `Clipmunk.dmg` from the [latest release](../../releases/latest).
2. Open the DMG and drag **Clipmunk** to your Applications folder.
3. Double-click **Clipmunk** to launch.

The DMG is signed with an Apple Developer ID certificate and notarized by Apple,
so it opens normally — no Gatekeeper warnings and no Terminal workaround needed.

### First run

- Clipmunk downloads the models it needs on first use, with a visible progress bar:
  the **Director** (Gemma 4 E2B ≈ 3.6 GB), the **Marlin-2B** vision model (≈ 2.5 GB, used
  for the always-on perception pass) and the transcription model (Parakeet ≈ 0.6 GB, or
  **WhisperKit large-v3** for non-English). Happens once, then it works offline.
- Open **Settings** (⌘,) and add your [Upload-Post](https://upload-post.com) **API key**
  and **profile name** (the one from *Manage Users*, not your social handle).
- Optionally set a caption language and paste a few of your own captions as style
  examples — the model will match your voice.

You can generate shorts without Upload-Post; only publishing/scheduling needs it.

## Build from source

You need **Xcode 16+** and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
On Apple Silicon. macOS 15+.

```bash
brew install xcodegen
git clone https://github.com/ngoldbla/clips
cd clips
xcodegen generate
open Clipmunk.xcodeproj
```

Build and run the **Clipmunk** scheme. The `.xcodeproj` is generated from
`project.yml` and intentionally not committed — `xcodegen` regenerates it.

> CLI builds need `-skipMacroValidation`:
> ```bash
> xcodebuild -project Clipmunk.xcodeproj -scheme Clipmunk \
>   -configuration Debug -skipMacroValidation -destination 'platform=macOS' build
> ```

### Release DMG

`.github/workflows/release.yml` builds a Developer ID-signed, notarized and
stapled `Clipmunk.dmg` and publishes it to the GitHub Release whenever a `v*`
tag is pushed:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Pre-release tags (e.g. `v0.1.0-rc1`) publish as GitHub **pre-releases**; final
`vX.Y.Z` tags publish as full releases. Signing and notarization require the
`DEVID_CERT_P12_BASE64`, `DEVID_CERT_PASSWORD`, `APPLE_TEAM_ID`, `NOTARY_KEY_P8`,
`NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` repository secrets.

## The stack

| Layer            | Used                                                                  |
|------------------|-----------------------------------------------------------------------|
| UI               | SwiftUI · AVKit                                                       |
| Transcription    | [Parakeet](https://github.com/soniqo/speech-swift) (CoreML/ANE, default on ≤16 GB) · [WhisperKit](https://github.com/argmaxinc/WhisperKit) `large-v3` fallback + non-English |
| Director model   | Gemma 4 E2B (4-bit), runs as a text LLM via MLX — finds moments + writes captions |
| Vision map | Marlin-2B (8-bit) — always-on perception: watches the footage, hands the Director an on-screen track |
| Faceless voice (opt) | Kokoro-82M (CoreML/ANE) via [speech-swift](https://github.com/soniqo/speech-swift) — swaps a clip's audio for a synth voiceover, re-syncs captions |
| Inference        | [MLX](https://github.com/ml-explore/mlx-swift) (Metal, Neural Engine) |
| Gemma 4 runtime  | [gemma-4-swift-mlx](https://github.com/VincentGourbin/gemma-4-swift-mlx), vendored in `Vendor/` |
| Vertical reframe | Vision (face detection) + AVFoundation (transform ramps / Core Image)|
| Media            | AVFoundation (cut, sample, export) · AVKit playback                  |
| Publishing       | [Upload-Post](https://upload-post.com) API (publish + schedule)      |
| Build            | XcodeGen · GitHub Actions                                            |

## Privacy

Transcription, moment-finding, captioning, cutting and reframing all run inside the app,
on your Mac. The only outbound traffic before you publish is:

- **First use only**: one-time downloads of the model weights from Hugging Face.
- **On Publish / Schedule**: an upload to Upload-Post with the rendered short and the copy
  you approved (immediately, or at the scheduled time).

Your Upload-Post API key is stored locally on your Mac (app preferences) and is only ever
sent to Upload-Post over HTTPS when you publish. It is never written into the repository.

## Known limitations

- The **Director** (Gemma 4 E2B) runs on-device. On an M1 Pro, a ~2-minute video takes a
  few minutes end-to-end (transcription + generation). Faster Macs (M3/M4) are quicker.
- One video at a time — no history, no batch processing. By design, for now.
- Upload-Post free tier limits monthly uploads. One publish to three networks counts as
  three.

## Acknowledgements

- **The Shortcast project** — the open-source (Apache 2.0) app Clipmunk is forked from and built upon.
- **Google** for the Gemma 4 family — open weights with full multimodal capability.
- **Apple's MLX team** for [MLX](https://github.com/ml-explore/mlx-swift) and
  [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm).
- **Vincent Gourbin** for [gemma-4-swift-mlx](https://github.com/VincentGourbin/gemma-4-swift-mlx),
  the native Gemma 4 runtime we vendor.
- **Argmax** for [WhisperKit](https://github.com/argmaxinc/WhisperKit).
- **Upload-Post** for the cross-platform publishing API.

## License

Apache License 2.0 — see [LICENSE](LICENSE). Clipmunk is a derivative work of the
Shortcast project (Apache 2.0); the original attribution is retained in [NOTICE](NOTICE).

Third-party components are listed in [NOTICE](NOTICE). The vendored
`gemma-4-swift-mlx` runtime is MIT-licensed; the Gemma 4 weights are governed by
[Google's Gemma Terms of Use](https://ai.google.dev/gemma/terms).

<div align="center">
<sub>Built in the open.</sub>
</div>
