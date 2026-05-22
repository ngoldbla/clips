# Shortcast

**Drop in a short video. Get three ready-to-post captions. Publish everywhere at once.**

Shortcast is a native macOS app that turns a short vertical video — a TikTok, a
Reel, a Short — into platform-tailored copy for **TikTok**, **Instagram Reels**
and **YouTube Shorts**. You review the three drafts, edit anything you want, and
publish to all three with one button.

The video never leaves your Mac during processing. Everything is generated
on-device by **Gemma 4 E4B**, Google's open multimodal model, running on Apple
Silicon through [MLX](https://github.com/ml-explore/mlx-swift). No Python, no
Electron, no embedded runtime — just Swift.

> Status: early. v0.1 — built in the open.

## How it works

1. **Drop a video** onto the window (up to ~60 seconds).
2. Shortcast samples frames and extracts the audio with **AVFoundation**, then
   hands them to **Gemma 4 E4B**.
3. The model watches and listens, then writes a hook, a caption and hashtags
   for each of the three platforms — guided by a built-in copywriting skill
   (`social-content-coach`) and, optionally, examples of your own style.
4. You get **three editable cards**. Tweak anything.
5. Press **Publish**. Shortcast sends the original video and your copy to all
   three networks through the [Upload-Post](https://upload-post.com) API.

Processing a clip typically takes **10–30 seconds**.

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon (M1 or newer)
- ~16 GB of memory recommended (Gemma 4 E4B uses ~7 GB while running)
- ~6 GB of free disk space for the model
- An [Upload-Post](https://upload-post.com) account to publish (free tier available)

## Install

1. Download `Shortcast.dmg` from the [latest release](../../releases/latest).
2. Open the `.dmg` and drag **Shortcast** to your Applications folder.
3. The app is **not signed with an Apple Developer ID** yet, so macOS will block
   the first launch. To allow it:
   - Double-click Shortcast. macOS says it can't verify the developer.
   - Open **System Settings → Privacy & Security**, scroll down, and click
     **Open Anyway** next to the Shortcast message.
   - Confirm once more. macOS remembers the choice from then on.
   - *(Power-user alternative: `xattr -dr com.apple.quarantine /Applications/Shortcast.app`.)*

This is normal for open-source Mac apps. Code signing and notarization are
planned once the project settles.

## First run

- On first launch Shortcast downloads **Gemma 4 E4B** (~5 GB) with a progress
  bar. This happens once; afterwards the app works fully offline for processing.
- Open **Settings** (⌘,) and add your **Upload-Post API key** and **profile
  name**:
  - Sign up at [upload-post.com](https://upload-post.com), then connect TikTok,
    Instagram and YouTube in the [dashboard](https://app.upload-post.com).
  - The **profile name** is the one from *Manage Users* — not a social handle.
  - Generate an API key in the dashboard settings.
- Optionally set a caption **language** (otherwise it matches the video) and
  paste a few **style examples** so the copy sounds like you.

## Build from source

You need Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone https://github.com/<owner>/shortcast
cd shortcast
xcodegen generate
open Shortcast.xcodeproj
```

Build and run the **Shortcast** scheme. The Xcode project is generated from
`project.yml` and is intentionally not committed.

Release `.dmg` builds are produced automatically by GitHub Actions
(`.github/workflows/release.yml`) whenever a `v*` tag is pushed.

## The stack

| Piece            | What                                                              |
|------------------|-------------------------------------------------------------------|
| UI               | SwiftUI, native macOS                                             |
| On-device model  | Gemma 4 E4B (4-bit), multimodal — text + vision + audio + video   |
| Inference        | [MLX](https://github.com/ml-explore/mlx-swift) on Apple Silicon   |
| Gemma 4 runtime  | [gemma-4-swift-mlx](https://github.com/VincentGourbin/gemma-4-swift-mlx), vendored in `Vendor/` |
| Media extraction | AVFoundation (frame sampling + audio)                             |
| Publishing       | [Upload-Post](https://upload-post.com) API                        |

## Privacy

Your video is processed **entirely on your Mac**. Nothing is uploaded during
analysis. The video and your captions are sent to a network only when you press
**Publish**, and only to the Upload-Post API so it can post them for you.

## Known limitations (v0.1)

- Gemma 4's audio encoder hears up to **30 seconds**. For longer clips the model
  still samples frames across the whole video, but only the first 30s of audio.
- The app is unsigned (see *Install*).
- One video at a time — no history, no batch. By design, for now.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

The vendored `gemma-4-swift-mlx` runtime is MIT-licensed; see
[NOTICE](NOTICE) for full third-party attribution. Gemma 4 model weights are
downloaded from Hugging Face at first run and are subject to
[Google's Gemma Terms of Use](https://ai.google.dev/gemma/terms).
