<div align="center">

# Shortcast

**One short video → ready-to-post copy for TikTok, Instagram Reels and YouTube Shorts.**
**Generated fully on your Mac. Open-source.**

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-1d1d1f)
![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)
![Model](https://img.shields.io/badge/Gemma_4_E4B-on--device-4285F4)

<br />

<img src="assets/demo.gif" alt="Shortcast demo — drop a short video, get three editable platform previews" width="720" />

<br />

<sub>Drop a clip → it watches and listens → three editable phone-style previews → publish to all three at once.</sub>

</div>

---

## What it does

You drop a short vertical video onto the window. About 30 seconds later, Shortcast gives
you **three editable post previews** — one for **TikTok**, one for **Instagram Reels**,
one for **YouTube Shorts** — each rendered as a phone mockup with **your video playing
behind the real platform UI**. Tap any line of caption to edit it. Hit Publish and the
same clip goes out to all three networks with the right copy for each.

What's different about Shortcast:

- 🛰️ **Nothing leaves your Mac during processing.** No cloud model, no upload.
  Your video is only sent to a network when you choose to publish it.
- 🧠 **Real multimodal understanding** — Gemma 4 E4B watches the frames *and* hears
  the audio. The captions actually reflect what's in the clip.
- ✏️ **Edit on the preview itself.** No abstract form — you see the post like it'll
  look on the feed, and type directly on it.
- 🎯 **Tuned per platform.** TikTok gets punchy. Instagram gets storytelling and 20–30
  hashtags. YouTube gets short, search-friendly titles. Driven by a bundled writing
  skill ([`social-content-coach.md`](Shortcast/Resources/social-content-coach.md)).
- 🪶 **No Python. No Electron. No embedded runtime.** Just Swift, MLX, AVFoundation.
  The whole app weighs ~50 MB; the model downloads on first launch.

## How the video processing works

```
  ┌──────────────────────────────────────────────────────────────────┐
  │  YOUR MAC — nothing leaves until you press Publish               │
  │                                                                  │
  │   drop ┐                                                         │
  │        ▼                                                         │
  │   ┌──────────────┐   frames   ┌─────────────────┐                │
  │   │ AVFoundation │──────────► │                 │   JSON with    │
  │   │              │   audio    │ Gemma 4 E4B     │──► 3 variants  │
  │   │ frame sampler│──────────► │ via MLX (Metal) │                │
  │   │ + audio mux  │   prompt   │                 │                │
  │   └──────────────┘─────────►  └─────────────────┘                │
  │        ▲                                                         │
  │        │                              │                          │
  │        │                              ▼                          │
  │        │                      ┌─────────────────┐                │
  │        │                      │ 3 phone-style   │  edit in       │
  │        │                      │ post previews   │  place         │
  │        └──── original video ──┤ (video + chrome │                │
  │                               │  + your copy)   │                │
  │                               └─────────────────┘                │
  └──────────────────────────────────────────────────────────────────┘
                                          │  press Publish
                                          ▼
                                  ┌─────────────────┐
                                  │   Upload-Post   │   one HTTP call,
                                  │       API       │   three networks
                                  └─────────────────┘
```

Concretely, when you drop a clip:

1. **AVFoundation** samples ~16 keyframes evenly across the video and exports the audio
   track to a small temp file. Frame extraction is built into the
   [vendored Gemma 4 runtime](Vendor/gemma-4-swift-mlx); we only need to peel off the
   audio.
2. The frames, audio, and a multi-section prompt — your bundled writing skill, the
   creator's style examples (optional), a language hint, and a strict JSON schema —
   are handed to **Gemma 4 E4B**.
3. **MLX-Swift** runs the model on the Apple Silicon GPU and Neural Engine. The
   "audio tower" hears up to 30 seconds; the vision encoder processes frames at
   ~1 fps with timestamps.
4. The model returns a single JSON object with three platform variants. A
   tolerant parser strips any code fences or thinking tokens and builds the
   structured result.
5. SwiftUI renders the **three phone mockups** — your video looping behind the real
   platform chrome (action rail, follow/subscribe button, music disc, dynamic island),
   with the hook/caption/hashtags as editable text overlays.
6. On **Publish**, the original video and your per-platform copy are sent in a single
   multipart `POST` to [Upload-Post](https://upload-post.com), which fans it out to
   TikTok, Instagram and YouTube. TikTok lands as a draft by default so you can finish
   in-app.

## Install

> Releases are unsigned, open-source binaries. macOS will flag them the first time —
> that's normal.

1. Download `Shortcast.dmg` from the [latest release](../../releases/latest).
2. Open the DMG and drag **Shortcast** to your Applications folder.
3. Double-click Shortcast. macOS says it can't verify the developer.
4. Open **System Settings → Privacy & Security**, scroll to the message about Shortcast,
   and click **Open Anyway**. Confirm once. macOS remembers from now on.

<details>
<summary>Power-user shortcut</summary>

```bash
xattr -dr com.apple.quarantine /Applications/Shortcast.app
```
</details>

### First run

- Shortcast downloads **Gemma 4 E4B** (~5 GB) with a visible progress bar. Happens once,
  then it works offline for analysis.
- Open **Settings** (⌘,) and add your [Upload-Post](https://upload-post.com) **API key**
  and **profile name** (the one from *Manage Users*, not your social handle).
- Optionally set a caption language and paste a few of your own captions as style
  examples — the model will match your voice.

You can generate posts without Upload-Post; only publishing needs it.

## Build from source

You need **Xcode 16+** and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
On Apple Silicon. macOS 15+.

```bash
brew install xcodegen
git clone https://github.com/mutonby/shortcast
cd shortcast
xcodegen generate
open Shortcast.xcodeproj
```

Build and run the **Shortcast** scheme. The `.xcodeproj` is generated from
`project.yml` and intentionally not committed — `xcodegen` regenerates it.

There's also a headless dev tool, `shortcast-probe`, that exercises the real
generation path on a chosen video:

```bash
xcodebuild -scheme shortcast-probe -configuration Debug build -derivedDataPath build
./build/Build/Products/Debug/shortcast-probe path/to/clip.mp4
```

### Release DMG

`.github/workflows/release.yml` builds an unsigned `.dmg` and attaches it to the
GitHub Release whenever a `v*` tag is pushed:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## The stack

| Layer            | Used                                                                  |
|------------------|-----------------------------------------------------------------------|
| UI               | SwiftUI · AVKit                                                       |
| On-device model  | Gemma 4 E4B (4-bit), text + vision + audio + video                    |
| Inference        | [MLX](https://github.com/ml-explore/mlx-swift) (Metal, Neural Engine) |
| Gemma 4 runtime  | [gemma-4-swift-mlx](https://github.com/VincentGourbin/gemma-4-swift-mlx), vendored in `Vendor/` |
| Media extraction | AVFoundation (frame sampling + audio export)                          |
| Publishing       | [Upload-Post](https://upload-post.com) API                            |
| Secrets          | macOS Keychain                                                        |
| Build            | XcodeGen · GitHub Actions                                             |

## Privacy

The video itself is **not** uploaded during analysis. Everything — frame sampling,
audio mel-spectrogram, model inference, JSON parsing — runs inside the app, on your
Mac. The only outbound traffic before you publish is:

- **First run only**: a one-time download of the Gemma 4 weights from Hugging Face.
- **On Publish**: a single multipart upload to Upload-Post, with your video and the
  copy you approved.

Your API key lives in the macOS Keychain, never in plist or settings files.

## Known limitations

- Gemma 4's audio encoder hears the **first 30 seconds**. Frames cover the whole clip,
  but if the punchline is at second 50 in audio, the model won't hear it.
- The app is **unsigned** (see *Install*). Code signing + notarization will come once
  the project stabilises.
- One video at a time — no history, no batch processing, no in-app account linking.
  By design, for now.
- Upload-Post free tier limits monthly uploads. One publish to three networks counts
  as three.

## Acknowledgements

- **Google** for the Gemma 4 family — open weights with full multimodal capability are
  what makes this app possible.
- **Apple's MLX team** for [MLX](https://github.com/ml-explore/mlx-swift) and
  [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm).
- **Vincent Gourbin** for [gemma-4-swift-mlx](https://github.com/VincentGourbin/gemma-4-swift-mlx),
  the native Gemma 4 runtime we vendor.
- **Upload-Post** for the cross-platform publishing API.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

Third-party components are listed in [NOTICE](NOTICE). The vendored
`gemma-4-swift-mlx` runtime is MIT-licensed; the Gemma 4 weights are governed by
[Google's Gemma Terms of Use](https://ai.google.dev/gemma/terms).

<div align="center">
<sub>Built in the open.</sub>
</div>
