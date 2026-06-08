# Parakeet STT + Kokoro TTS (faceless narration) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a low-memory on-device STT engine (Parakeet via `soniqo/speech-swift`, WhisperKit kept as fallback) and an opt-in faceless-narration TTS feature (Kokoro-82M) that replaces a clip's audio with a synthesized voiceover and re-syncs its captions — without regressing the green Gemma 4 E2B / Marlin baseline.

**Architecture:** Phase 4 puts transcription behind an `ASREngine` protocol and routes Parakeet (constrained Macs, English/unset) vs WhisperKit (non-English / 24 GB+ / fallback) entirely *inside* `TranscriptionService` — its public `transcript(for:languageHint:)` surface is unchanged, so `WorkspaceModel` and the probes don't move. Phase 5 adds narration as a **pre-stage**: a `NarrationService` (Kokoro) synthesizes audio from the clip's script, a pure `NarrationComposer` swaps that audio onto the clip and reconciles duration (freeze-hold/trim), and the *existing* render pipeline (`VerticalReframer`/`VideoOverlayRenderer`) runs unchanged on the narrated clip with proportionally re-synced captions. Neither engine exposes word timestamps, so captions use the existing proportional `Transcript.synthesizeWords` in both paths.

**Tech Stack:** Swift 6 / macOS 15, MLX (existing), AVFoundation (compose/export), `soniqo/speech-swift` (`ParakeetStreamingASR` + `KokoroTTS` + `AudioCommon`, CoreML/ANE), WhisperKit (bumped 0.9 → 1.0), XcodeGen (`project.yml`), headless `type: tool` probes for validation.

**Reference spec:** `docs/superpowers/specs/2026-06-07-lean-model-lineup-and-tts-design.md` — §6 (Parakeet), §7 (Kokoro), §14 (locked decisions + verified facts). Read §14 before starting.

**Project guardrail (from the user's handoff):** Do **not** push, and do **not** commit unless the user has approved committing. Each task ends with a commit step for the natural boundary; if commits are not yet approved, keep the changes staged and pause at the checkpoint instead of running `git commit`.

**How to build / validate (no XCTest target exists — validation is probe-based):**
- Build the app (Debug, unsigned): `bash scripts/dev-build.sh`
- Build a single probe: `xcodebuild -project Clipmunk.xcodeproj -scheme <probe-name> -configuration Debug -skipMacroValidation -skipPackagePluginValidation -derivedDataPath build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- Regenerate the Xcode project after any `project.yml` change: `xcodegen generate`
- Test video: any speech clip in `~/Downloads` (e.g. a tutorial/talk `.mp4`). There is **no** `.context/testcase/` in a fresh workspace.
- Pre-warm model caches to avoid slow first runs on a ~1.7 MB/s link: `hf download <repo>` (full, no `--include`).

---

## File Structure

**New files (Phase 4 — STT):**
- `Clipmunk/Services/ASREngine.swift` — the `ASREngine` protocol (the engine seam). One responsibility: define the engine contract + shared phase callback type alias.
- `Clipmunk/Services/WhisperKitEngine.swift` — today's WhisperKit download/load/transcribe code, moved behind `ASREngine`. Owns the `WhisperKit?` instance and its lifecycle.
- `Clipmunk/Services/ParakeetEngine.swift` — Parakeet via `speech-swift`: resample → stream → per-utterance proportional segmentation. Owns the Parakeet model instance.
- `Clipmunk/Services/AudioResampler.swift` — pure AVFoundation helper: any audio file → 16 kHz mono `Float32` `[Float]`. No model deps → unit/probe-testable.

**New files (Phase 5 — TTS):**
- `Clipmunk/Services/VoiceCatalog.swift` — enumerate installed Kokoro voices at runtime from the model bundle, grouped by language prefix; default `af_heart`.
- `Clipmunk/Services/NarrationService.swift` — `actor` owning the single Kokoro model: `synthesize(text:voiceID:) -> [Float]` (+ `unload()`).
- `Clipmunk/Services/NarrationComposer.swift` — pure AVFoundation: write `[Float]@24k` to an audio track, swap it onto the clip, reconcile duration (trim / freeze-hold last frame). No model deps → testable.
- `NarrationProbe/main.swift` — headless end-to-end narration probe + `--selftest` mode for the pure helpers.

**Modified files:**
- `project.yml` — bump WhisperKit → 1.0.0; add `speech-swift` (`exact: "0.0.20"`); add new product deps to app + probe targets; add new source files to each probe's explicit `sources`; add the `narration-probe` target.
- `Clipmunk/Services/TranscriptionService.swift` — becomes the router; WhisperKit body moves out; keeps `Transcript`/`TranscriptSegment`/`synthesizeWords`/sidecar/`languageCode`.
- `Clipmunk/Services/ModelCatalog.swift` — add `stt` (Parakeet) + `tts` (Kokoro) entries; keep `transcription` as the WhisperKit/fallback descriptor.
- `Clipmunk/Services/MemoryPolicy.swift` — add `shouldFreeASRAfterTranscribe`; refresh stale 12B/E4B doc comments.
- `Clipmunk/Models/AppSettings.swift` — add `ttsEnabled` (off) + `ttsVoiceID` (`af_heart`).
- `Clipmunk/Views/SettingsView.swift` — dynamic STT name; new "Faceless voiceover" section (toggle + runtime voice picker).
- `Clipmunk/Models/ShortClip.swift` — `narrationEnabled` + `narrationVoiceID`; narration branch in `makeRenderedFile()`; `narrationText` source; persist in `stored()`/`restoring:`.
- `Clipmunk/Services/JobLibrary.swift` — `StoredClip` gains `narrationEnabled` + `narrationVoiceID` (additive, Codable-safe).
- `Clipmunk/Services/WorkspaceModel.swift` — `shouldFreeWhisperAfterTranscribe` → `shouldFreeASRAfterTranscribe` (2 sites); seed narration defaults in the `ShortClip(...)` constructor.
- `ShortsProbe/main.swift` — `--stt parakeet|whisperkit` + `--narrate` flags; use the renamed memory flag.

---

## PHASE 0 — Make the dependency graph green (the hard blocker)

`speech-swift` requires `WhisperKit >= 1.0.0`; Clipmunk pins `from: "0.9.0"` (resolves ≤ 0.18.0). The ranges are disjoint, so `swift package resolve` fails today. Nothing else can build until this is fixed. **Do this first and in isolation** so the WhisperKit-major adaptation is a clean, reviewable diff.

### Task 0.1: Add `speech-swift`, bump WhisperKit, resolve the graph

**Files:**
- Modify: `project.yml:31-35` (packages), `project.yml:43-57` (app deps)

- [ ] **Step 1: Edit `project.yml` packages.** Replace the WhisperKit package entry and add `speech-swift`. Find (lines ~31-35):

```yaml
  # On-device transcription, used only as a fallback when a long video has no
  # .srt/.vtt alongside it. Lazy: the Whisper model never downloads otherwise.
  WhisperKit:
    url: https://github.com/argmaxinc/WhisperKit
    from: "0.9.0"
```

Replace with:

```yaml
  # On-device transcription. WhisperKit is now the FALLBACK STT (Parakeet is the
  # default on constrained Macs); still the non-English path. Bumped 0.9 -> 1.0
  # because speech-swift requires WhisperKit >= 1.0.0 (disjoint with 0.9.x).
  WhisperKit:
    url: https://github.com/argmaxinc/WhisperKit
    from: "1.0.0"
  # Parakeet TDT (STT) + Kokoro-82M (TTS) as CoreML/ANE via one package
  # (internally "Qwen3Speech"). Pinned exact: it ships no upstream Package.resolved,
  # so this is the only way to keep the resolved graph reproducible. We import only
  # ParakeetStreamingASR + KokoroTTS + AudioCommon.
  speech-swift:
    url: https://github.com/soniqo/speech-swift
    exact: "0.0.20"
```

- [ ] **Step 2: Add the new products to the app target.** In `project.yml`, the `Clipmunk` target `dependencies:` (after the `WhisperKit` product entry at ~line 56-57), add:

```yaml
      - package: speech-swift
        product: ParakeetStreamingASR
      - package: speech-swift
        product: KokoroTTS
      - package: speech-swift
        product: AudioCommon
```

- [ ] **Step 3: Regenerate + resolve.** Run:

```bash
xcodegen generate
xcodebuild -resolvePackageDependencies -project Clipmunk.xcodeproj -scheme Clipmunk
```

Expected: resolution **succeeds** (it fails before this change). Note the resolved `swift-transformers` version printed/installed (see Step 4).

- [ ] **Step 4: Verify the swift-transformers float.** WhisperKit 1.0 drops its `swift-transformers` dependency, removing the old transitive `<1.2.0` cap; `project.yml:28-30` keeps `from: "1.1.6"` (i.e. `[1.1.6, 2.0.0)`). Check the resolved version:

```bash
grep -A3 '"swift-transformers"' Clipmunk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

If it resolved to a 1.1.x or 1.2.x that the Gemma/MLX stack compiles against (verified in Task 0.2), leave it. **If Task 0.2's build fails on a swift-transformers API**, pin it deliberately by changing `project.yml:28-30` `from: "1.1.6"` to a fixed `exact: "<version that builds>"` and re-running Step 3. Record the chosen version in a comment.

- [ ] **Step 5: Commit** (if commits are approved; else stage + pause).

```bash
git add project.yml Clipmunk.xcodeproj
git commit -m "build: add speech-swift (exact 0.0.20), bump WhisperKit 0.9->1.0 for graph resolution"
```

### Task 0.2: Adapt `TranscriptionService` to the WhisperKit 1.0 API

WhisperKit 0.x → 1.0 is a SemVer-major; the four WhisperKit call sites may have changed. This is a **compile-driven** task: build, read each error, fix it, rebuild. Before starting, fetch the WhisperKit 1.0.0 API for the call sites below (use context7 `resolve-library-id` + `query-docs` for "argmaxinc/WhisperKit", or read the 1.0.0 release notes / `WhisperKit` public headers in `build/.../checkouts/WhisperKit/Sources`).

**Files:**
- Modify: `Clipmunk/Services/TranscriptionService.swift:181-244` (the four WhisperKit call sites)

The current call sites that may need adapting (do not assume; verify against 1.0):
1. `WhisperKit.recommendedModels()` → `support.supported` / `support.default` (line 183-185). In some 1.x builds this became `async`.
2. `WhisperKit.download(variant:) { progress in ... }` (line 187-192).
3. `WhisperKit(WhisperKitConfig(modelFolder:computeOptions:load:))` + `ModelComputeOptions(melCompute:audioEncoderCompute:textDecoderCompute:)` (lines 200-205).
4. `whisper.transcribe(audioPath:decodeOptions:)` returning `[TranscriptionResult]` with `.segments` / `.language` / segment `.words` (lines 228-240); `DecodingOptions()` fields `.task`, `.wordTimestamps`, `.language`, `.detectLanguage`.

- [ ] **Step 1: Build to surface the breaks.** Run `bash scripts/dev-build.sh`. Expected: it builds OR fails with WhisperKit-related compiler errors. Capture every WhisperKit error.

- [ ] **Step 2: Fix each error against the 1.0 API.** For each compiler error, apply the 1.0 equivalent (e.g. add `await` if a call became async, rename a renamed parameter, adjust a result field). Keep behaviour identical: GPU compute units (`.cpuAndGPU` for mel/audioEncoder/textDecoder), `wordTimestamps = true`, forced-vs-auto language detection. Do **not** change the audio-path approach here (still `audioPath:`).

- [ ] **Step 3: Rebuild until green.** Run `bash scripts/dev-build.sh`. Expected: `built: build/Build/Products/Debug/Clipmunk.app` with no errors. If a swift-transformers error appears, apply Task 0.1 Step 4's pin.

- [ ] **Step 4: Smoke-test WhisperKit still transcribes (probe).** This proves the major bump didn't regress transcription. Run the existing pipeline probe on a real speech video:

```bash
xcodebuild -project Clipmunk.xcodeproj -scheme shorts-probe -configuration Debug -skipMacroValidation -skipPackagePluginValidation -derivedDataPath build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
build/Build/Products/Debug/shorts-probe ~/Downloads/<speech>.mp4 .context/samples 1
```

Expected stderr line: `transcript: N segments, M word-stamps, lang=en ...` with M > 0, then `SHORTS_OK clips=1`.

- [ ] **Step 5: Commit** (if approved).

```bash
git add Clipmunk/Services/TranscriptionService.swift
git commit -m "fix: adapt TranscriptionService to WhisperKit 1.0 API (green build, transcription verified)"
```

**CHECKPOINT 0:** The app builds green on WhisperKit 1.0 with `speech-swift` resolved, and WhisperKit transcription is verified unregressed. Stop and review before Phase 4.

---

## PHASE 4 — Parakeet STT behind `ASREngine`

### Task 4.1: Add the `AudioResampler` (16 kHz mono Float32) — pure + testable first

**Files:**
- Create: `Clipmunk/Services/AudioResampler.swift`
- Modify: `project.yml` (add to `shorts-probe` and the new `narration-probe` sources later)

- [ ] **Step 1: Write the failing probe self-test.** We have no XCTest target; the probe is the test runner. Add a self-test to `ShortsProbe/main.swift` *temporarily* (it will be replaced by `NarrationProbe --selftest` in Task 5.x; for now prove the resampler). At the very top of `ShortsProbe/main.swift`, after the helper funcs (~line 18), insert:

```swift
// TEMP self-test for AudioResampler (Task 4.1). Run: shorts-probe --selftest-resampler <anyAudioOrVideo>
if CommandLine.arguments.contains("--selftest-resampler") {
    guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) else {
        print("usage: shorts-probe --selftest-resampler <audio-or-video>"); exit(1)
    }
    do {
        let samples = try await AudioResampler.pcm16kMono(from: URL(fileURLWithPath: path))
        let seconds = Double(samples.count) / 16000.0
        precondition(!samples.isEmpty, "resampler returned no samples")
        precondition(seconds > 0.1, "resampler produced < 0.1s of audio")
        print("RESAMPLER_OK samples=\(samples.count) seconds=\(String(format: "%.2f", seconds))")
        exit(0)
    } catch { print("RESAMPLER_FAILED \(error)"); exit(1) }
}
```

Add `Clipmunk/Services/AudioResampler.swift` to `shorts-probe` `sources:` in `project.yml` (after `MediaExtractor.swift`, ~line 170).

- [ ] **Step 2: Run it to verify it fails.**

```bash
xcodegen generate
xcodebuild -project Clipmunk.xcodeproj -scheme shorts-probe -configuration Debug -skipMacroValidation -skipPackagePluginValidation -derivedDataPath build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: **compile failure** — `AudioResampler` is undefined.

- [ ] **Step 3: Implement `AudioResampler`.** Create `Clipmunk/Services/AudioResampler.swift`:

```swift
import AVFoundation
import Foundation

/// Converts any audio/video file's audio track into the exact format Parakeet
/// (and WhisperKit's array API) want: 16 kHz, mono, 32-bit float PCM as `[Float]`.
///
/// Source audio off an `AVAsset` is usually 44.1/48 kHz stereo, so a single
/// `AVAudioConverter` pass does both the sample-rate conversion AND the
/// stereo→mono downmix. Pure AVFoundation — no model dependency — so it can be
/// validated headlessly without loading any ASR model.
enum AudioResampler {

    enum ResampleError: LocalizedError {
        case noAudioTrack
        case converterUnavailable
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:       return "That file has no audio track to resample."
            case .converterUnavailable: return "Couldn't create the 16 kHz audio converter."
            case .readFailed(let d):  return "Couldn't read audio for resampling: \(d)"
            }
        }
    }

    /// Decodes `url`'s audio to 16 kHz mono Float32 PCM samples.
    static func pcm16kMono(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard inFormat.channelCount > 0 else { throw ResampleError.noAudioTrack }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000,
            channels: 1, interleaved: false)
        else { throw ResampleError.converterUnavailable }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw ResampleError.converterUnavailable
        }

        // Read the whole file in chunks, feeding the converter on demand.
        let readChunk: AVAudioFrameCount = 16384
        guard let inBuffer = AVAudioPCMBuffer(
            pcmFormat: inFormat, frameCapacity: readChunk) else {
            throw ResampleError.converterUnavailable
        }

        var out: [Float] = []
        var reachedEOF = false

        while !reachedEOF {
            // Output buffer sized generously for the (down)sampled chunk.
            let outCapacity = AVAudioFrameCount(
                Double(readChunk) * (16000.0 / inFormat.sampleRate) + 1024)
            guard let outBuffer = AVAudioPCMBuffer(
                pcmFormat: outFormat, frameCapacity: outCapacity) else {
                throw ResampleError.converterUnavailable
            }

            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                inBuffer.frameLength = 0
                do {
                    try file.read(into: inBuffer, frameCount: readChunk)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }

            if let conversionError { throw ResampleError.readFailed(conversionError.localizedDescription) }

            if let channel = outBuffer.floatChannelData, outBuffer.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(
                    start: channel[0], count: Int(outBuffer.frameLength)))
            }

            if status == .endOfStream || status == .error { reachedEOF = true }
        }

        return out
    }
}
```

- [ ] **Step 4: Run the self-test to verify it passes.**

```bash
xcodegen generate
xcodebuild -project Clipmunk.xcodeproj -scheme shorts-probe -configuration Debug -skipMacroValidation -skipPackagePluginValidation -derivedDataPath build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
build/Build/Products/Debug/shorts-probe --selftest-resampler ~/Downloads/<speech>.mp4
```

Expected: `RESAMPLER_OK samples=<N> seconds=<~videolen>` (seconds should match the source clip length within ~1%).

- [ ] **Step 5: Commit** (if approved).

```bash
git add Clipmunk/Services/AudioResampler.swift project.yml ShortsProbe/main.swift
git commit -m "feat(stt): AudioResampler -> 16kHz mono Float32 (probe self-test green)"
```

### Task 4.2: Add the `ASREngine` protocol + move WhisperKit behind it

**Files:**
- Create: `Clipmunk/Services/ASREngine.swift`, `Clipmunk/Services/WhisperKitEngine.swift`
- Modify: `Clipmunk/Services/TranscriptionService.swift` (extract the WhisperKit body), `project.yml` (add both files to `shorts-probe` sources)

- [ ] **Step 1: Create the protocol.** Create `Clipmunk/Services/ASREngine.swift`:

```swift
import Foundation

/// An on-device speech-to-text engine. `TranscriptionService` owns one or more
/// and picks per job (Parakeet on constrained Macs / English; WhisperKit
/// otherwise and as a hard fallback). The public transcription surface
/// (`TranscriptionService.transcript(for:languageHint:)`) is unchanged — the
/// engine choice is entirely internal.
@MainActor
protocol ASREngine: AnyObject {
    /// Transcribes the audio at `audioURL` (an extracted `.m4a`). `languageHint`
    /// is a user override ("es", "Spanish") or empty for auto. `onPhase` reports
    /// progress so the service can surface download/transcribe state in the UI.
    func transcribe(
        audioURL: URL, languageHint: String,
        onPhase: @escaping (TranscriptionService.Phase) -> Void
    ) async throws -> Transcript

    /// Releases the in-memory model. Weights stay cached on disk.
    func unload()
}
```

- [ ] **Step 2: Move the WhisperKit body into `WhisperKitEngine`.** Create `Clipmunk/Services/WhisperKitEngine.swift` by lifting the model + download + transcribe logic verbatim out of `TranscriptionService.transcribeOnDevice` / `unload` / `preferredVariants`:

```swift
import Foundation
@preconcurrency import WhisperKit

/// WhisperKit ASR — multilingual, accurate, ~2 GB CoreML. The STT fallback
/// (Parakeet is preferred on constrained Macs) and the non-English path. This is
/// the pre-existing transcription code, now behind `ASREngine`.
@MainActor
final class WhisperKitEngine: ASREngine {

    private var whisper: WhisperKit?

    /// Whisper variants to prefer, best-first; falls back to the device default.
    /// MUST be multilingual — distil-* models are English-only and turn other
    /// languages into gibberish, so they are deliberately excluded.
    private static let preferredVariants = [
        "openai_whisper-large-v3",
        "openai_whisper-large-v3_947MB",
        "openai_whisper-small",
    ]

    func transcribe(
        audioURL: URL, languageHint: String,
        onPhase: @escaping (TranscriptionService.Phase) -> Void
    ) async throws -> Transcript {
        if whisper == nil {
            onPhase(.downloadingModel(fraction: 0))
            let support = WhisperKit.recommendedModels()   // adapt to 1.0 if async
            let variant = Self.preferredVariants.first { support.supported.contains($0) }
                ?? support.default
            TranscriptionService.log("whisper variant: \(variant)")
            let folder = try await WhisperKit.download(variant: variant) { @Sendable progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    onPhase(fraction < 1.0 ? .downloadingModel(fraction: fraction) : .preparingModel)
                }
            }
            onPhase(.preparingModel)
            // Force GPU compute units — the ANE specialization of large-v3 is
            // pathologically slow on M1 Pro.
            let compute = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU)
            whisper = try await WhisperKit(WhisperKitConfig(
                modelFolder: folder.path, computeOptions: compute, load: true))
            TranscriptionService.log("whisper model loaded")
        }
        guard let whisper else { throw TranscriptionError.modelUnavailable }

        onPhase(.transcribing)
        var options = DecodingOptions()
        options.task = .transcribe
        options.wordTimestamps = true
        if let code = TranscriptionService.languageCode(from: languageHint) {
            options.language = code
            options.detectLanguage = false
        } else {
            options.detectLanguage = true
        }
        let results = try await whisper.transcribe(audioPath: audioURL.path, decodeOptions: options)
        let segments = results.flatMap(\.segments).map { seg in
            TranscriptSegment(
                start: Double(seg.start), end: Double(seg.end), text: seg.text,
                words: (seg.words ?? []).compactMap { w in
                    let t = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? nil : WordStamp(text: t, start: Double(w.start), end: Double(w.end))
                })
        }
        guard !segments.isEmpty else { throw TranscriptionError.empty }
        return Transcript(segments: segments, language: results.first?.language)
    }

    func unload() {
        guard whisper != nil else { return }
        whisper = nil
        TranscriptionService.log("whisper unloaded")
    }
}
```

(If Task 0.2 changed any WhisperKit call, mirror those exact changes here — this is the same code relocated.)

- [ ] **Step 3: Reduce `TranscriptionService` to the router.** In `Clipmunk/Services/TranscriptionService.swift`: remove `@preconcurrency import WhisperKit` (line 4), the `whisper` property (line 126), `preferredVariants` (lines 132-139), and the WhisperKit body of `transcribeOnDevice` (lines 174-245) and `unload` (lines 165-170). Keep `Transcript`/`TranscriptSegment`/`synthesizeWords`/sidecar parsing/`languageCode`/`Phase`. Replace the removed members with:

```swift
    private(set) var phase: Phase = .idle

    private let whisperEngine = WhisperKitEngine()
    // Parakeet is added in Task 4.4; until then this stays nil and the router
    // always uses WhisperKit (behaviour identical to before).
    private lazy var parakeetEngine: ASREngine? = nil

    func unload() {
        whisperEngine.unload()
        parakeetEngine?.unload()
        phase = .idle
    }

    private func transcribeOnDevice(_ videoURL: URL, languageHint: String = "") async throws -> Transcript {
        guard let audioURL = try await MediaExtractor.extractAudio(from: videoURL, maxSeconds: nil) else {
            throw TranscriptionError.noAudio
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let engine = whisperEngine   // routing added in Task 4.4
        return try await engine.transcribe(
            audioURL: audioURL, languageHint: languageHint,
            onPhase: { [weak self] p in self?.phase = p })
    }
```

Keep `nonisolated static func log` and `static func languageCode` exactly as they are (the engines call them).

- [ ] **Step 4: Add both files to `shorts-probe` sources** in `project.yml` (after `TranscriptionService.swift`, ~line 163):

```yaml
      - path: Clipmunk/Services/ASREngine.swift
      - path: Clipmunk/Services/WhisperKitEngine.swift
```

- [ ] **Step 5: Build + re-run the WhisperKit smoke test.**

```bash
bash scripts/dev-build.sh
xcodebuild -project Clipmunk.xcodeproj -scheme shorts-probe -configuration Debug -skipMacroValidation -skipPackagePluginValidation -derivedDataPath build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
build/Build/Products/Debug/shorts-probe ~/Downloads/<speech>.mp4 .context/samples 1
```

Expected: app builds green; probe prints `transcript: N segments, M>0 word-stamps` and `SHORTS_OK` — i.e. the refactor is behaviour-preserving.

- [ ] **Step 6: Commit** (if approved).

```bash
git add Clipmunk/Services/ASREngine.swift Clipmunk/Services/WhisperKitEngine.swift Clipmunk/Services/TranscriptionService.swift project.yml
git commit -m "refactor(stt): introduce ASREngine; move WhisperKit behind it (no behaviour change)"
```

### Task 4.3: Pure per-utterance proportional segmentation (testable core of Parakeet)

Parakeet returns **no timestamps**, so the engine assigns each utterance a `[start,end]` proportional to its char length over the known total audio duration, then `synthesizeWords` fills word stamps within each short utterance. This distribution is pure → test it first.

**Files:**
- Create: `Clipmunk/Services/ParakeetEngine.swift` (segmentation helper only, this task)
- Modify: `ShortsProbe/main.swift` (self-test), `project.yml` (add `ParakeetEngine.swift` to `shorts-probe`)

- [ ] **Step 1: Write the failing self-test.** In `ShortsProbe/main.swift`, after the resampler self-test block, add:

```swift
if CommandLine.arguments.contains("--selftest-segments") {
    let utts = ["Hello there friend", "this is a test"]   // 17 vs 14 chars (incl. spaces)
    let segs = ParakeetSegmenter.segmentize(utterances: utts, totalDuration: 10)
    precondition(segs.count == 2, "expected 2 segments, got \(segs.count)")
    precondition(segs[0].start == 0, "first segment must start at 0")
    precondition(abs(segs.last!.end - 10) < 0.001, "last segment must end at totalDuration")
    precondition(segs[0].end > segs[1].start - 0.001 && segs[1].start >= segs[0].end - 0.001,
                 "segments must be contiguous")
    precondition(segs[0].words.isEmpty, "Parakeet segments carry no word stamps (synthesized later)")
    // Longer utterance gets more time.
    precondition((segs[0].end - segs[0].start) > (segs[1].end - segs[1].start),
                 "longer utterance should get a longer span")
    print("SEGMENTS_OK \(segs.map { String(format: "%.2f-%.2f", $0.start, $0.end) })")
    exit(0)
}
```

Add `Clipmunk/Services/ParakeetEngine.swift` to `shorts-probe` `sources:` in `project.yml`.

- [ ] **Step 2: Run it; verify it fails** (`ParakeetSegmenter` undefined). Build `shorts-probe` as before → compile error.

- [ ] **Step 3: Implement the segmenter.** Create `Clipmunk/Services/ParakeetEngine.swift` with just the pure helper for now:

```swift
import Foundation

/// Turns Parakeet's timestamp-less utterance texts into `TranscriptSegment`s by
/// distributing the known total audio duration across them in proportion to each
/// utterance's character length. Word stamps are left empty on purpose — the
/// existing `Transcript.synthesizeWords` fills them per segment, which keeps the
/// proportional drift bounded to a single short utterance (decision §14.1).
enum ParakeetSegmenter {
    static func segmentize(utterances: [String], totalDuration: Double) -> [TranscriptSegment] {
        let clean = utterances
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !clean.isEmpty, totalDuration > 0 else { return [] }

        let weights = clean.map { Double(max(1, $0.count)) }
        let total = weights.reduce(0, +)
        var cursor = 0.0
        var segments: [TranscriptSegment] = []
        for (i, text) in clean.enumerated() {
            let end = (i == clean.count - 1) ? totalDuration
                                             : cursor + totalDuration * (weights[i] / total)
            segments.append(TranscriptSegment(start: cursor, end: max(end, cursor), text: text, words: []))
            cursor = end
        }
        return segments
    }
}
```

- [ ] **Step 4: Run; verify it passes.** Build + `build/Build/Products/Debug/shorts-probe --selftest-segments`. Expected: `SEGMENTS_OK ["0.00-5.45", "5.45-10.00"]` (longer first utterance gets the larger span).

- [ ] **Step 5: Commit** (if approved).

```bash
git add Clipmunk/Services/ParakeetEngine.swift project.yml ShortsProbe/main.swift
git commit -m "feat(stt): ParakeetSegmenter (proportional per-utterance segments, self-test green)"
```

### Task 4.4: Implement `ParakeetEngine` + route it in `TranscriptionService`

**Files:**
- Modify: `Clipmunk/Services/ParakeetEngine.swift` (add the engine), `Clipmunk/Services/TranscriptionService.swift` (routing + hard fallback)

- [ ] **Step 1: Add the engine to `ParakeetEngine.swift`.** Append (verify the `speech-swift` API names against the resolved package source under `build/.../checkouts/speech-swift/Sources/ParakeetStreamingASR`; §14 lists the verified shapes):

```swift
import ParakeetStreamingASR

/// Parakeet TDT ASR via soniqo/speech-swift (CoreML/ANE, ~hundreds of MB).
/// Preferred on constrained Macs for English/unset audio. Returns text only
/// (no timestamps) — utterances are time-bounded proportionally by
/// `ParakeetSegmenter`, then word stamps are synthesized downstream.
@MainActor
final class ParakeetEngine: ASREngine {

    private var model: ParakeetStreamingASRModel?

    func transcribe(
        audioURL: URL, languageHint: String,
        onPhase: @escaping (TranscriptionService.Phase) -> Void
    ) async throws -> Transcript {
        let samples = try AudioResampler.pcm16kMono(from: audioURL)
        guard !samples.isEmpty else { throw TranscriptionError.empty }
        let totalDuration = Double(samples.count) / 16000.0

        if model == nil {
            onPhase(.downloadingModel(fraction: 0))
            model = try await ParakeetStreamingASRModel.fromPretrained { fraction, _ in
                Task { @MainActor in
                    onPhase(fraction < 1.0 ? .downloadingModel(fraction: fraction) : .preparingModel)
                }
            }
        }
        guard let model else { throw TranscriptionError.modelUnavailable }

        onPhase(.transcribing)
        // Collect the final text per utterance (segmentIndex), in order.
        var utteranceText: [Int: String] = [:]
        var order: [Int] = []
        for await partial in model.transcribeStream(audio: samples, sampleRate: 16000, chunkDuration: nil) {
            guard partial.isFinal else { continue }
            if utteranceText[partial.segmentIndex] == nil { order.append(partial.segmentIndex) }
            utteranceText[partial.segmentIndex] = partial.text
        }
        var utterances = order.compactMap { utteranceText[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // If the stream produced one giant utterance, split into sentences so the
        // proportional segmentation still bounds drift.
        if utterances.count <= 1, let whole = utterances.first {
            utterances = Self.splitSentences(whole)
        }

        let segments = ParakeetSegmenter.segmentize(utterances: utterances, totalDuration: totalDuration)
        guard !segments.isEmpty else { throw TranscriptionError.empty }
        TranscriptionService.log("parakeet: \(segments.count) utterance segment(s) over \(String(format: "%.1f", totalDuration))s")
        return Transcript(segments: segments, language: TranscriptionService.languageCode(from: languageHint) ?? "en")
    }

    func unload() { model = nil }

    /// Splits a block of text into sentence-ish utterances on . ? ! boundaries.
    private static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "?" || ch == "!" {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out.isEmpty ? [text] : out
    }
}
```

- [ ] **Step 2: Add routing + hard fallback in `TranscriptionService`.** Replace the Task 4.2 placeholders. Set up the Parakeet engine and the engine choice:

```swift
    private lazy var parakeetEngine: ASREngine? = ParakeetEngine()
```

And rewrite `transcribeOnDevice` to route + fall back:

```swift
    private func transcribeOnDevice(_ videoURL: URL, languageHint: String = "") async throws -> Transcript {
        guard let audioURL = try await MediaExtractor.extractAudio(from: videoURL, maxSeconds: nil) else {
            throw TranscriptionError.noAudio
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        // Parakeet when RAM is tight AND the language is English/unset; otherwise
        // WhisperKit (non-English, or 24 GB+ where accuracy is free).
        let hint = TranscriptionService.languageCode(from: languageHint)
        let englishOrUnset = (hint == nil || hint == "en")
        let useParakeet = MemoryPolicy.isConstrained && englishOrUnset

        if useParakeet, let parakeet = parakeetEngine {
            do {
                return try await parakeet.transcribe(
                    audioURL: audioURL, languageHint: languageHint,
                    onPhase: { [weak self] p in self?.phase = p })
            } catch {
                // Hard fallback: any Parakeet failure must not lose transcription.
                TranscriptionService.log("parakeet failed (\(error)) — falling back to WhisperKit")
                parakeet.unload()
            }
        }
        return try await whisperEngine.transcribe(
            audioURL: audioURL, languageHint: languageHint,
            onPhase: { [weak self] p in self?.phase = p })
    }
```

- [ ] **Step 3: Add `ParakeetEngine.swift` to the `Clipmunk` app target** — it's already covered by `sources: - path: Clipmunk`, so no project.yml change for the app. Confirm it's in `shorts-probe` sources (added Task 4.3). Add `AudioResampler.swift` to `shorts-probe` too if not already (Task 4.1 added it).

- [ ] **Step 4: Pre-warm the Parakeet model** to avoid a slow first run:

```bash
hf download aufklarer/Parakeet-TDT-v3-CoreML-INT8-30s
```

- [ ] **Step 5: Build app + probe.** `bash scripts/dev-build.sh` then build `shorts-probe`. Expected: green.

- [ ] **Step 6: Commit** (if approved).

```bash
git add Clipmunk/Services/ParakeetEngine.swift Clipmunk/Services/TranscriptionService.swift project.yml
git commit -m "feat(stt): ParakeetEngine + memory/language routing with WhisperKit hard fallback"
```

### Task 4.5: Catalog, memory policy, settings label, orchestrator rename

**Files:**
- Modify: `Clipmunk/Services/ModelCatalog.swift`, `Clipmunk/Services/MemoryPolicy.swift:8-13,34-36`, `Clipmunk/Views/SettingsView.swift:77`, `Clipmunk/Services/WorkspaceModel.swift:204,258`, `ShortsProbe/main.swift:36`

- [ ] **Step 1: Add catalog entries.** In `Clipmunk/Services/ModelCatalog.swift`, after the `transcription` entry (line 62), add:

```swift
    /// Low-memory ASR (CoreML/ANE) via speech-swift. Preferred on constrained
    /// Macs for English/unset audio; falls back to `transcription` (WhisperKit).
    static let stt = Entry(
        role: .stt,
        repoID: "aufklarer/Parakeet-TDT-v3-CoreML-INT8-30s",
        displayName: "Parakeet TDT",
        estPeakRAMGB: 0.6)

    /// Faceless-narration TTS (CoreML/ANE) via speech-swift. Synthesizes the
    /// clip's script; the picker enumerates installed voices at runtime.
    static let tts = Entry(
        role: .tts,
        repoID: "aufklarer/Kokoro-82M-CoreML",
        displayName: "Kokoro-82M",
        estPeakRAMGB: 0.2)
```

- [ ] **Step 2: Generalize the memory flag + refresh stale comments.** In `Clipmunk/Services/MemoryPolicy.swift`, replace the stale doc comment (lines 8-13, which still names "Gemma 4 12B ≈ 13 GB" / "E4B copywriter") with the current lineup, and add the generalized flag after line 36:

```swift
    /// Free the ASR model (WhisperKit ~2 GB CoreML, or Parakeet ~hundreds of MB)
    /// after transcription, before the Director loads — on 16 GB the two
    /// shouldn't be resident together. Supersedes `shouldFreeWhisperAfterTranscribe`.
    static var shouldFreeASRAfterTranscribe: Bool { isConstrained }
```

Keep `shouldFreeWhisperAfterTranscribe` for one commit to avoid a wide rename in the same step, OR remove it and update both call sites now (Step 4). Choose removal for cleanliness.

- [ ] **Step 3: Dynamic STT name in Settings.** In `Clipmunk/Views/SettingsView.swift:77`, change `model: ModelCatalog.transcription.displayName,` to a runtime-aware label:

```swift
                    model: MemoryPolicy.isConstrained
                        ? "\(ModelCatalog.stt.displayName) · \(ModelCatalog.transcription.displayName) fallback"
                        : ModelCatalog.transcription.displayName,
```

- [ ] **Step 4: Rename the flag at both call sites.** In `Clipmunk/Services/WorkspaceModel.swift` change `shouldFreeWhisperAfterTranscribe` → `shouldFreeASRAfterTranscribe` at lines 204 and 258. In `ShortsProbe/main.swift:36` change the same. (These are the only references — confirm with a grep.)

- [ ] **Step 5: Build app + probe.** `bash scripts/dev-build.sh` and build `shorts-probe`. Expected: green; no remaining references to the old flag (`grep -rn shouldFreeWhisperAfterTranscribe` returns nothing).

- [ ] **Step 6: Commit** (if approved).

```bash
git add Clipmunk/Services/ModelCatalog.swift Clipmunk/Services/MemoryPolicy.swift Clipmunk/Views/SettingsView.swift Clipmunk/Services/WorkspaceModel.swift ShortsProbe/main.swift
git commit -m "feat(stt): catalog stt/tts entries, shouldFreeASRAfterTranscribe, dynamic STT label"
```

### Task 4.6: Validate Parakeet end-to-end via the probe

**Files:**
- Modify: `ShortsProbe/main.swift` (add a `--stt parakeet|whisperkit` flag)

- [ ] **Step 1: Add an STT override to the probe.** The probe constructs `TranscriptionService()` and calls `transcript(for:languageHint:)`. Add a env/flag to force the engine for A/B. Simplest: read an env var in `TranscriptionService.transcribeOnDevice` under `#if DEBUG` (mirrors the existing `CLIPMUNK_*` debug pattern). In `transcribeOnDevice`, before computing `useParakeet`, add:

```swift
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["CLIPMUNK_STT"] {
            if forced == "whisperkit" {
                return try await whisperEngine.transcribe(
                    audioURL: audioURL, languageHint: languageHint,
                    onPhase: { [weak self] p in self?.phase = p })
            }
            if forced == "parakeet", let parakeet = parakeetEngine {
                return try await parakeet.transcribe(
                    audioURL: audioURL, languageHint: languageHint,
                    onPhase: { [weak self] p in self?.phase = p })
            }
        }
        #endif
```

- [ ] **Step 2: Run both engines on the same clip and compare.**

```bash
bash scripts/dev-build.sh   # rebuild app is not needed for the probe, but keep green
xcodebuild -project Clipmunk.xcodeproj -scheme shorts-probe -configuration Debug -skipMacroValidation -skipPackagePluginValidation -derivedDataPath build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
CLIPMUNK_STT=parakeet   build/Build/Products/Debug/shorts-probe ~/Downloads/<speech>.mp4 .context/samples/parakeet 2
CLIPMUNK_STT=whisperkit build/Build/Products/Debug/shorts-probe ~/Downloads/<speech>.mp4 .context/samples/whisper 2
```

Expected: both print `SHORTS_OK clips=2`. Parakeet's `transcript:` line shows multiple utterance segments and synthesized word-stamps (M>0). Eyeball one frame of each to confirm captions render and roughly track the speech:

```bash
ffmpeg -y -ss 3 -i .context/samples/parakeet/sample-1-*.mp4 -frames:v 1 .context/samples/parakeet-f.png
ffmpeg -y -ss 3 -i .context/samples/whisper/sample-1-*.mp4 -frames:v 1 .context/samples/whisper-f.png
```

- [ ] **Step 3: Verify the hard fallback.** Temporarily break Parakeet (e.g. set `CLIPMUNK_STT=parakeet` and rename the cached model dir so `fromPretrained` fails offline) and confirm the default (non-forced) run still produces a transcript via WhisperKit. Restore the cache afterward.

- [ ] **Step 4: Commit** (if approved).

```bash
git add ShortsProbe/main.swift Clipmunk/Services/TranscriptionService.swift
git commit -m "test(stt): probe --stt A/B override; verified Parakeet path + WhisperKit fallback"
```

**CHECKPOINT 4:** Parakeet transcribes on the constrained path with proportional per-utterance captions; WhisperKit remains for non-English / roomy Macs and as a hard fallback; the app and `shorts-probe` build green. Stop and review before Phase 5.

---

## PHASE 5 — Kokoro TTS faceless narration

### Task 5.1: `VoiceCatalog` — enumerate installed voices at runtime

**Files:**
- Create: `Clipmunk/Services/VoiceCatalog.swift`

- [ ] **Step 1: Locate the voices.** Kokoro voices ship as `voices/*.json` inside the downloaded model bundle at `~/Library/Caches/qwen3-speech/...` (see §14). First, after a one-time Kokoro download (`hf download aufklarer/Kokoro-82M-CoreML`), inspect the bundle layout to confirm the exact `voices/` path:

```bash
find ~/Library/Caches/qwen3-speech -name '*.json' -path '*voice*' | head
```

Record the directory pattern; the implementation globs it.

- [ ] **Step 2: Implement `VoiceCatalog`.** Create `Clipmunk/Services/VoiceCatalog.swift`:

```swift
import Foundation

/// One selectable Kokoro voice, with a human label and language group derived
/// from its id prefix (af_/am_ American, bf_/bm_ British, jf_/jm_ Japanese,
/// zf_/zm_ Chinese, …).
struct Voice: Identifiable, Sendable, Equatable {
    let id: String          // e.g. "af_heart"
    var displayName: String // e.g. "Heart (American ♀)"
    var group: String       // e.g. "American English"
}

/// Enumerates the voices actually present in the downloaded Kokoro bundle, so the
/// picker can never list a voice the bundle lacks. Falls back to the package
/// default (`af_heart`) when the bundle hasn't been downloaded yet.
enum VoiceCatalog {

    static let defaultVoiceID = "af_heart"

    /// All installed voice ids found under the speech-swift cache, sorted by group
    /// then id. Empty array means "not downloaded yet" — callers should fall back
    /// to `defaultVoiceID`.
    static func installed() -> [Voice] {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else {
            return []
        }
        let root = caches.appendingPathComponent("qwen3-speech", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }

        var ids = Set<String>()
        for case let url as URL in enumerator
        where url.pathExtension == "json" && url.deletingLastPathComponent().lastPathComponent == "voices" {
            ids.insert(url.deletingPathExtension().lastPathComponent)
        }
        return ids.map(makeVoice).sorted { ($0.group, $0.id) < ($1.group, $1.id) }
    }

    /// A display Voice for any id, prefix-decoded (works even before download).
    static func makeVoice(_ id: String) -> Voice {
        let prefix = String(id.prefix(2))
        let (group, sex): (String, String)
        switch prefix {
        case "af": (group, sex) = ("American English", "♀")
        case "am": (group, sex) = ("American English", "♂")
        case "bf": (group, sex) = ("British English", "♀")
        case "bm": (group, sex) = ("British English", "♂")
        case "jf": (group, sex) = ("Japanese", "♀")
        case "jm": (group, sex) = ("Japanese", "♂")
        case "zf": (group, sex) = ("Chinese", "♀")
        case "zm": (group, sex) = ("Chinese", "♂")
        default:   (group, sex) = ("Other", "")
        }
        let name = id.split(separator: "_").dropFirst().joined(separator: " ").capitalized
        return Voice(id: id, displayName: "\(name.isEmpty ? id : name) (\(group) \(sex))".trimmingCharacters(in: .whitespaces),
                     group: group)
    }
}
```

- [ ] **Step 3: Build the app** (`bash scripts/dev-build.sh`). Expected: green. (Runtime enumeration is validated in Task 5.7's probe.)

- [ ] **Step 4: Commit** (if approved).

```bash
git add Clipmunk/Services/VoiceCatalog.swift
git commit -m "feat(tts): VoiceCatalog enumerates installed Kokoro voices at runtime"
```

### Task 5.2: `NarrationService` — Kokoro lifecycle + synthesize

**Files:**
- Create: `Clipmunk/Services/NarrationService.swift`

- [ ] **Step 1: Implement the service.** Create `Clipmunk/Services/NarrationService.swift` (verify the `KokoroTTS` API against the resolved package source; §14 lists the verified shapes — note `synthesize` is synchronous/throwing and `fromPretrained` is async):

```swift
import Foundation
import KokoroTTS

/// Owns the single Kokoro-82M model and synthesizes narration audio. An `actor`
/// so the model (one CoreML instance) is never used concurrently. ~200 MB, loads
/// lazily at render time (after the Director is freed), and can be unloaded.
actor NarrationService {

    static let shared = NarrationService()

    /// Kokoro's fixed output sample rate (verified in source).
    static let sampleRate: Double = 24000

    private var model: KokoroTTSModel?

    /// Synthesizes `text` in `voiceID` to 24 kHz mono Float32 samples.
    func synthesize(text: String, voiceID: String) async throws -> [Float] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw NarrationError.emptyScript }
        if model == nil { model = try await KokoroTTSModel.fromPretrained() }
        guard let model else { throw NarrationError.modelUnavailable }
        // Call synthesize(voice:) directly — NOT the protocol generate(), which
        // hardwires the default voice and ignores voiceID.
        let samples = try model.synthesize(text: clean, voice: voiceID)
        guard !samples.isEmpty else { throw NarrationError.emptyAudio }
        return samples
    }

    func unload() { model = nil }

    enum NarrationError: LocalizedError {
        case emptyScript, modelUnavailable, emptyAudio
        var errorDescription: String? {
            switch self {
            case .emptyScript:     return "There's no script text to narrate."
            case .modelUnavailable: return "The narration voice couldn't be loaded."
            case .emptyAudio:      return "Narration produced no audio."
            }
        }
    }
}
```

- [ ] **Step 2: Build the app.** Expected: green. (Runtime synth validated in Task 5.7 — this is where the metallib question gets answered empirically.)

- [ ] **Step 3: Commit** (if approved).

```bash
git add Clipmunk/Services/NarrationService.swift
git commit -m "feat(tts): NarrationService (Kokoro lifecycle + synthesize)"
```

### Task 5.3: `NarrationComposer` — audio-swap + duration reconcile (pure, testable)

**Files:**
- Create: `Clipmunk/Services/NarrationComposer.swift`
- Modify: `NarrationProbe/main.swift` (created in Task 5.7; for this task add a temporary self-test to `ShortsProbe/main.swift`)

- [ ] **Step 1: Write the failing self-test.** In `ShortsProbe/main.swift`, add a self-test that synthesizes a sine `[Float]` (no model needed) and reconciles a real clip to it, asserting the output duration matches the narration length for BOTH the trim and freeze-hold cases:

```swift
if CommandLine.arguments.contains("--selftest-narrate-compose") {
    guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) else {
        print("usage: shorts-probe --selftest-narrate-compose <video>"); exit(1) }
    let clip = URL(fileURLWithPath: path)
    func sine(seconds: Double) -> [Float] {
        let n = Int(seconds * NarrationService.sampleRate)
        return (0..<n).map { Float(sin(Double($0) * 2 * .pi * 220 / NarrationService.sampleRate)) * 0.2 }
    }
    do {
        let clipDur = CMTimeGetSeconds(try await AVURLAsset(url: clip).load(.duration))
        // Case A: narration SHORTER than clip -> trim.
        let shortURL = try await NarrationComposer.narratedClip(
            clipURL: clip, samples: sine(seconds: max(1, clipDur - 1)), sampleRate: NarrationService.sampleRate)
        let shortDur = CMTimeGetSeconds(try await AVURLAsset(url: shortURL.url).load(.duration))
        precondition(abs(shortDur - shortURL.narrationLen) < 0.3, "trim case off: \(shortDur) vs \(shortURL.narrationLen)")
        // Case B: narration LONGER than clip -> freeze-hold.
        let longURL = try await NarrationComposer.narratedClip(
            clipURL: clip, samples: sine(seconds: clipDur + 2), sampleRate: NarrationService.sampleRate)
        let longDur = CMTimeGetSeconds(try await AVURLAsset(url: longURL.url).load(.duration))
        precondition(abs(longDur - longURL.narrationLen) < 0.5, "freeze case off: \(longDur) vs \(longURL.narrationLen)")
        try? FileManager.default.removeItem(at: shortURL.url)
        try? FileManager.default.removeItem(at: longURL.url)
        print("NARRATE_COMPOSE_OK trim=\(String(format: "%.1f", shortDur)) freeze=\(String(format: "%.1f", longDur))")
        exit(0)
    } catch { print("NARRATE_COMPOSE_FAILED \(error)"); exit(1) }
}
```

Add `import AVFoundation` at the top of `ShortsProbe/main.swift` if not present, and add `Clipmunk/Services/NarrationComposer.swift` + `Clipmunk/Services/NarrationService.swift` to `shorts-probe` sources in `project.yml` (NarrationService is needed only for `sampleRate`; if its `import KokoroTTS` pulls weight into the probe, instead hardcode `24000` in the test and skip adding NarrationService to the probe).

- [ ] **Step 2: Run; verify it fails** (`NarrationComposer` undefined).

- [ ] **Step 3: Implement `NarrationComposer`.** Create `Clipmunk/Services/NarrationComposer.swift`:

```swift
import AVFoundation
import Foundation

/// Replaces a clip's audio with synthesized narration samples and reconciles the
/// clip's duration to the narration length (decision §14: freeze-hold the last
/// frame when the video is shorter, trim when it's longer). Pure AVFoundation —
/// no TTS model dependency — so it's validated headlessly with a synthetic tone.
enum NarrationComposer {

    /// Builds a new temp `.mp4` whose audio IS `samples` and whose video runs for
    /// exactly the narration length. The existing render pipeline then runs on
    /// this clip unchanged and copies the narration audio for free.
    /// Returns the URL (caller deletes it) and the narration length in seconds.
    static func narratedClip(
        clipURL: URL, samples: [Float], sampleRate: Double
    ) async throws -> (url: URL, narrationLen: Double) {
        let narrationLen = Double(samples.count) / sampleRate
        guard narrationLen > 0 else { throw MediaExtractorError.clipExportFailed("empty narration") }

        // 1. Write samples to a temp audio file (mono Float32 @ sampleRate).
        let audioURL = try writeAudio(samples: samples, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let videoAsset = AVURLAsset(url: clipURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let srcVideo = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw MediaExtractorError.noVideoTrack
        }
        guard let srcAudio = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw MediaExtractorError.clipExportFailed("narration audio track missing")
        }
        let videoDur = CMTimeGetSeconds(try await videoAsset.load(.duration))
        let narration = CMTime(seconds: narrationLen, preferredTimescale: 600)

        let comp = AVMutableComposition()
        guard let compVideo = comp.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudio = comp.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaExtractorError.clipExportFailed("composition tracks") }

        compVideo.preferredTransform = try await srcVideo.load(.preferredTransform)

        if narrationLen <= videoDur {
            // Trim video to narration length.
            try compVideo.insertTimeRange(
                CMTimeRange(start: .zero, duration: narration), of: srcVideo, at: .zero)
        } else {
            // Full video, then FREEZE-HOLD the last frame for the remaining gap by
            // re-inserting a one-frame tail range and scaling it to the gap.
            let full = CMTimeRange(start: .zero, duration: CMTime(seconds: videoDur, preferredTimescale: 600))
            try compVideo.insertTimeRange(full, of: srcVideo, at: .zero)
            let fps = (try? await srcVideo.load(.nominalFrameRate)) ?? 30
            let frame = CMTime(seconds: 1.0 / Double(max(1, fps)), preferredTimescale: 600)
            let lastFrameStart = CMTime(seconds: max(0, videoDur) , preferredTimescale: 600) - frame
            let tail = CMTimeRange(start: lastFrameStart, duration: frame)
            let gap = CMTime(seconds: narrationLen - videoDur, preferredTimescale: 600)
            let insertAt = CMTime(seconds: videoDur, preferredTimescale: 600)
            try compVideo.insertTimeRange(tail, of: srcVideo, at: insertAt)
            compVideo.scaleTimeRange(CMTimeRange(start: insertAt, duration: frame), toDuration: gap)
        }

        // Audio = the full narration.
        try compAudio.insertTimeRange(
            CMTimeRange(start: .zero, duration: narration), of: srcAudio, at: .zero)

        // 2. Export.
        guard let export = AVAssetExportSession(
            asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaExtractorError.clipExportFailed("export session unavailable")
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipmunk-narrated-\(UUID().uuidString).mp4")
        do { try await export.export(to: out, as: .mp4) }
        catch { throw MediaExtractorError.clipExportFailed(error.localizedDescription) }
        return (out, narrationLen)
    }

    /// Writes mono Float32 samples to a temp `.caf` via `AVAudioFile`.
    private static func writeAudio(samples: [Float], sampleRate: Double) throws -> URL {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw MediaExtractorError.clipExportFailed("audio buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipmunk-narration-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
```

- [ ] **Step 4: Run; verify it passes.** Build `shorts-probe`; run `build/Build/Products/Debug/shorts-probe --selftest-narrate-compose ~/Downloads/<speech>.mp4`. Expected: `NARRATE_COMPOSE_OK trim=<~clip-1> freeze=<~clip+2>` (both within tolerance). Eyeball the freeze case isn't garbled (optional: export+ffmpeg a frame near the end).

- [ ] **Step 5: Commit** (if approved).

```bash
git add Clipmunk/Services/NarrationComposer.swift project.yml ShortsProbe/main.swift
git commit -m "feat(tts): NarrationComposer (audio swap + freeze-hold/trim, self-test green)"
```

### Task 5.4: Wire narration into `ShortClip.makeRenderedFile()` + caption re-sync + fallback

**Files:**
- Modify: `Clipmunk/Models/ShortClip.swift` (fields, `narrationText`, `makeRenderedFile`, `stored()`, `restoring:`)

- [ ] **Step 1: Add the fields + init params.** In `ShortClip` add stored properties after `captionStyle` (line 52):

```swift
    /// Per-clip switch for replacing the audio with a synthesized voiceover.
    var narrationEnabled: Bool
    /// Which Kokoro voice to narrate with (id like "af_heart").
    var narrationVoiceID: String
```

Update the primary `init` signature (line 61-64) to accept them (defaults keep existing call sites compiling):

```swift
    init(candidate: ClipCandidate, transcriptSlice: String,
         wordStamps: [WordStamp] = [],
         overlayEnabled: Bool, reframeEnabled: Bool,
         captionsEnabled: Bool = true, captionStyle: CaptionStyle = .default,
         narrationEnabled: Bool = false, narrationVoiceID: String = VoiceCatalog.defaultVoiceID) {
```

and assign them at the end of that init:

```swift
        self.narrationEnabled = narrationEnabled
        self.narrationVoiceID = narrationVoiceID
```

In the `restoring:` init (line 83-97) add:

```swift
        self.narrationEnabled = stored.narrationEnabled
        self.narrationVoiceID = stored.narrationVoiceID
```

- [ ] **Step 2: Add the narration text source (a marked decision point).** Add a computed property. This is a genuine editorial choice — narrate the long-form caption body, falling back to the hook, then the transcript slice:

```swift
    // ── DECISION (§7 source text): what the synthesized voice reads. ───────────
    // Faceless narration replaces the talking-head audio, so it should read the
    // Director's *script*, not echo the original speech. Default: the primary
    // platform caption body (PostVariant.summary), then the candidate hook, then
    // the transcript slice as a last resort. Kept short to stay near clip length.
    var narrationText: String {
        if let body = variants.first(where: { !$0.summary.trimmed.isEmpty })?.summary { return body }
        if !candidate.hook.trimmed.isEmpty { return candidate.hook }
        return transcriptSlice
    }
```

- [ ] **Step 3: Add the narration branch to `makeRenderedFile()`.** Replace `makeRenderedFile()` (lines 129-145) with a version that, when narration is on, builds the narrated clip + re-synced captions first, then runs the existing pipeline on it, with a clean fallback:

```swift
    private func makeRenderedFile() async throws -> (url: URL, isTemporary: Bool) {
        guard let clipJob else { throw MomentFinderError.notReady }
        let hook = overlayText.trimmed
        let wantReframe = reframeEnabled && isLandscape
        let wantOverlay = overlayEnabled && !hook.isEmpty
        let wantCaptions = captionsEnabled && !captionScript.isEmpty

        // Narration pre-stage: synthesize the script, swap it onto the clip, and
        // re-sync captions proportionally over the narration length. Any failure
        // falls through to today's path (original audio + transcript-timed captions).
        var sourceURL = clipJob.url
        var narratedTemp: URL?
        var renderCaptions: CaptionScript? = wantCaptions ? captionScript : nil
        if narrationEnabled, !narrationText.trimmed.isEmpty {
            do {
                let samples = try await NarrationService.shared.synthesize(
                    text: narrationText, voiceID: narrationVoiceID)
                let narrated = try await NarrationComposer.narratedClip(
                    clipURL: clipJob.url, samples: samples, sampleRate: NarrationService.sampleRate)
                sourceURL = narrated.url
                narratedTemp = narrated.url
                if wantCaptions {
                    let words = Transcript.synthesizeWords(
                        text: narrationText, start: 0, end: narrated.narrationLen)
                    renderCaptions = CaptionScript.build(words: words, clipStart: 0, clipEnd: narrated.narrationLen)
                }
            } catch {
                ShortClip.log("narration failed (\(error)) — rendering with original audio")
            }
        }

        // Existing render pipeline runs on `sourceURL` (narrated clip when on).
        if wantReframe || wantOverlay || (renderCaptions?.isEmpty == false),
           let url = try await VerticalReframer.process(
                clipURL: sourceURL,
                reframe: wantReframe,
                overlayText: wantOverlay ? hook : nil,
                captionScript: (renderCaptions?.isEmpty == false) ? renderCaptions : nil,
                captionStyle: captionStyle) {
            if let narratedTemp, narratedTemp != url { try? FileManager.default.removeItem(at: narratedTemp) }
            return (url, true)
        }

        // Nothing to burn. If we narrated, the narrated clip IS the output.
        if let narratedTemp { return (narratedTemp, true) }
        return (clipJob.url, false)
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[clipmunk/narration] \(message)\n".utf8))
    }
```

- [ ] **Step 4: Persist narration in `stored()`** (lines 101-110): add the two fields to the `StoredClip(...)` initializer call:

```swift
            captionStyleID: captionStyle.id,
            narrationEnabled: narrationEnabled, narrationVoiceID: narrationVoiceID,
            clipFile: "\(id.uuidString).mp4",
```

- [ ] **Step 5: Update `isRendered`** (lines 119-124) so narration-on clips are treated as rendered even with no reframe/overlay/captions:

```swift
    var isRendered: Bool {
        let wantReframe = reframeEnabled && isLandscape
        let wantOverlay = overlayEnabled && !overlayText.trimmed.isEmpty
        let wantCaptions = captionsEnabled && !captionScript.isEmpty
        return wantReframe || wantOverlay || wantCaptions || narrationEnabled
    }
```

- [ ] **Step 6: Build.** This will fail until `StoredClip` has the fields (Task 5.5). Do Task 5.5 next, then build both together.

### Task 5.5: Persist narration fields in `StoredClip`

**Files:**
- Modify: `Clipmunk/Services/JobLibrary.swift:7-22`

- [ ] **Step 1: Add the fields.** In `StoredClip`, after `captionStyleID` (line 18) add:

```swift
    var narrationEnabled: Bool
    var narrationVoiceID: String
```

These are additive; existing manifests decode fine only if the decoder tolerates missing keys. Since `StoredClip` uses the synthesized `Codable`, **old manifests would fail to decode** the new non-optional keys. To stay backward-compatible (reopen pre-narration jobs), give them defaults via a custom decode OR make them optional with computed defaults. Simplest backward-compatible approach: make them optional in storage and default on read:

```swift
    var narrationEnabled: Bool = false
    var narrationVoiceID: String = "af_heart"
```

A default value on a `var` in a `Codable` struct makes the synthesized decoder treat the key as optional (present → decoded, absent → default). This preserves reopen of old jobs. Keep the `ShortClip.stored()` call passing real values.

- [ ] **Step 2: Build the app.** Run `bash scripts/dev-build.sh`. Expected: green (ShortClip Task 5.4 + StoredClip now consistent).

- [ ] **Step 3: Commit** (if approved) — Tasks 5.4 + 5.5 together (they're interdependent).

```bash
git add Clipmunk/Models/ShortClip.swift Clipmunk/Services/JobLibrary.swift
git commit -m "feat(tts): narration branch in ShortClip render + StoredClip persistence (back-compatible)"
```

### Task 5.6: Settings + orchestrator wiring (toggle, voice picker, defaults)

**Files:**
- Modify: `Clipmunk/Models/AppSettings.swift` (new settings), `Clipmunk/Views/SettingsView.swift` (new section), `Clipmunk/Services/WorkspaceModel.swift:327-335` (seed defaults)

- [ ] **Step 1: Add settings.** In `AppSettings`, add two properties (after `visionAwareMomentFinding`, line 82):

```swift
    /// Default for replacing each short's audio with a synthesized voiceover
    /// ("faceless" mode). OFF by default — opt-in, per-clip overridable.
    var ttsEnabled: Bool {
        didSet { defaults.set(ttsEnabled, forKey: Keys.tts) }
    }

    /// Kokoro voice id used for narration (e.g. "af_heart").
    var ttsVoiceID: String {
        didSet { defaults.set(ttsVoiceID, forKey: Keys.ttsVoice) }
    }
```

In `init` (after line 129):

```swift
        self.ttsEnabled = defaults.object(forKey: Keys.tts) as? Bool ?? false
        self.ttsVoiceID = defaults.string(forKey: Keys.ttsVoice) ?? VoiceCatalog.defaultVoiceID
```

In `Keys` (after line 156):

```swift
        static let tts       = "clipmunk.ttsEnabled"
        static let ttsVoice  = "clipmunk.ttsVoiceID"
```

- [ ] **Step 2: Add the Settings section.** In `SettingsView.body`, after the "Vertical reframing" section (line 120), add:

```swift
            Section("Faceless voiceover (opt-in)") {
                Toggle("Replace each short's audio with an AI voiceover", isOn: $settings.ttsEnabled)
                if settings.ttsEnabled {
                    let voices = VoiceCatalog.installed()
                    Picker("Voice", selection: $settings.ttsVoiceID) {
                        if voices.isEmpty {
                            Text(VoiceCatalog.makeVoice(VoiceCatalog.defaultVoiceID).displayName)
                                .tag(VoiceCatalog.defaultVoiceID)
                        } else {
                            ForEach(voices) { v in Text(v.displayName).tag(v.id) }
                        }
                    }
                    if voices.isEmpty {
                        Text("More voices appear here after the \(ModelCatalog.tts.displayName) model downloads on first use.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Reads the short's script with \(ModelCatalog.tts.displayName) and replaces the clip's audio, re-syncing captions — turns a cut into a clean faceless/B-roll short. Off by default; flip per clip.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

- [ ] **Step 3: Seed per-clip defaults in the pipeline.** In `WorkspaceModel.runShortsPipeline`, the `clips = candidates.map { ShortClip(... ) }` block (lines 327-335) — add the two args:

```swift
            clips = candidates.map {
                ShortClip(candidate: $0,
                          transcriptSlice: transcript.slice(start: $0.start, end: $0.end),
                          wordStamps: transcript.wordStamps(start: $0.start, end: $0.end),
                          overlayEnabled: settings.burnHookOverlay,
                          reframeEnabled: settings.reframeToVertical,
                          captionsEnabled: settings.burnCaptions,
                          captionStyle: captionStyle,
                          narrationEnabled: settings.ttsEnabled,
                          narrationVoiceID: settings.ttsVoiceID)
            }
```

- [ ] **Step 4: Build the app.** Run `bash scripts/dev-build.sh`. Expected: green.

- [ ] **Step 5: Commit** (if approved).

```bash
git add Clipmunk/Models/AppSettings.swift Clipmunk/Views/SettingsView.swift Clipmunk/Services/WorkspaceModel.swift
git commit -m "feat(tts): faceless-voiceover setting + runtime voice picker + per-clip default"
```

### Task 5.7: `NarrationProbe` — end-to-end narration + metallib verification

**Files:**
- Create: `NarrationProbe/main.swift`
- Modify: `project.yml` (add the `narration-probe` target)

- [ ] **Step 1: Add the `narration-probe` target.** In `project.yml`, after the `shorts-probe` target (line 202), add a new target mirroring `shorts-probe`'s source list and adding the TTS files + `speech-swift` products:

```yaml
  # Developer-only headless narration probe: synthesize + audio-swap + reconcile
  # + reframe/captions on a real clip, writing a faceless sample .mp4. Also has a
  # --selftest mode for the pure helpers. This is where the Kokoro metallib
  # question is answered empirically (a real synthesize() runs here).
  narration-probe:
    type: tool
    platform: macOS
    sources:
      - path: NarrationProbe
      - path: Clipmunk/Services/TranscriptionService.swift
      - path: Clipmunk/Services/ASREngine.swift
      - path: Clipmunk/Services/WhisperKitEngine.swift
      - path: Clipmunk/Services/ParakeetEngine.swift
      - path: Clipmunk/Services/AudioResampler.swift
      - path: Clipmunk/Services/MomentFinderService.swift
      - path: Clipmunk/Services/ChatModelProfile.swift
      - path: Clipmunk/Services/ModelCatalog.swift
      - path: Clipmunk/Services/MemoryPolicy.swift
      - path: Clipmunk/Services/PromptBuilder.swift
      - path: Clipmunk/Services/JSONVariantParser.swift
      - path: Clipmunk/Services/MediaExtractor.swift
      - path: Clipmunk/Services/VerticalReframer.swift
      - path: Clipmunk/Services/VideoOverlayRenderer.swift
      - path: Clipmunk/Services/CaptionRenderer.swift
      - path: Clipmunk/Services/AudioActivityAnalyzer.swift
      - path: Clipmunk/Services/CaptionScript.swift
      - path: Clipmunk/Services/NarrationService.swift
      - path: Clipmunk/Services/NarrationComposer.swift
      - path: Clipmunk/Services/VoiceCatalog.swift
      - path: Clipmunk/Models/ClipCandidate.swift
      - path: Clipmunk/Models/PostVariant.swift
      - path: Clipmunk/Models/WordStamp.swift
      - path: Clipmunk/Models/VideoJob.swift
      - path: Clipmunk/Models/CaptionStyle.swift
      - path: Clipmunk/Models/String+Trimmed.swift
    dependencies:
      - package: Gemma4Swift
        product: Gemma4Swift
      - package: mlx-swift-lm
        product: MLXVLM
      - package: mlx-swift-lm
        product: MLXLMCommon
      - package: mlx-swift-lm
        product: MLXHuggingFace
      - package: swift-huggingface
        product: HuggingFace
      - package: swift-transformers
        product: Tokenizers
      - package: WhisperKit
        product: WhisperKit
      - package: speech-swift
        product: ParakeetStreamingASR
      - package: speech-swift
        product: KokoroTTS
      - package: speech-swift
        product: AudioCommon
    settings:
      base:
        PRODUCT_NAME: narration-probe
        SWIFT_VERSION: "6.0"
        MACOSX_DEPLOYMENT_TARGET: "15.0"
        GENERATE_INFOPLIST_FILE: YES
```

Also add the three `speech-swift` products to the existing `shorts-probe` dependencies so its `--stt parakeet` path links (mirror the block above).

- [ ] **Step 2: Write the probe.** Create `NarrationProbe/main.swift`:

```swift
import AVFoundation
import Foundation

func note(_ m: String) { FileHandle.standardError.write(Data("[narration-probe] \(m)\n".utf8)) }

// --selftest: voice enumeration + a real Kokoro synthesize (answers the metallib
// question) + compose, with no full pipeline.
if CommandLine.arguments.contains("--selftest") {
    let voices = VoiceCatalog.installed()
    note("installed voices: \(voices.count) — \(voices.prefix(5).map(\.id).joined(separator: ", "))…")
    do {
        let samples = try await NarrationService.shared.synthesize(
            text: "This is a Clipmunk narration test.", voiceID: VoiceCatalog.defaultVoiceID)
        let seconds = Double(samples.count) / NarrationService.sampleRate
        precondition(seconds > 0.5, "synthesized < 0.5s")
        print("NARRATION_SELFTEST_OK voices=\(voices.count) synth_seconds=\(String(format: "%.2f", seconds))")
        exit(0)
    } catch {
        // If this prints "Failed to load the default metallib", do Task 5.8.
        print("NARRATION_SELFTEST_FAILED \(error)"); exit(1)
    }
}

// End-to-end: synthesize from a provided script and render a faceless sample.
let args = CommandLine.arguments
guard args.count > 2 else { print("usage: narration-probe <video> <script-text> [voice=af_heart] [outDir=.context/samples]"); exit(1) }
let videoURL = URL(fileURLWithPath: args[1])
let script = args[2]
let voice = args.count > 3 ? args[3] : VoiceCatalog.defaultVoiceID
let outDir = URL(fileURLWithPath: args.count > 4 ? args[4] : ".context/samples")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

MemoryPolicy.configureMLX()
do {
    let cutDur = CMTimeGetSeconds(try await AVURLAsset(url: videoURL).load(.duration))
    let samples = try await NarrationService.shared.synthesize(text: script, voiceID: voice)
    let narrated = try await NarrationComposer.narratedClip(
        clipURL: videoURL, samples: samples, sampleRate: NarrationService.sampleRate)
    note("narration \(String(format: "%.1f", narrated.narrationLen))s vs clip \(String(format: "%.1f", cutDur))s")
    let words = Transcript.synthesizeWords(text: script, start: 0, end: narrated.narrationLen)
    let captions = CaptionScript.build(words: words, clipStart: 0, clipEnd: narrated.narrationLen)
    let landscape = await VerticalReframer.isLandscape(url: narrated.url)
    let rendered = try await VerticalReframer.process(
        clipURL: narrated.url, reframe: landscape, overlayText: nil,
        captionScript: captions, captionStyle: .default)
    let finalURL = rendered ?? narrated.url
    let dest = outDir.appendingPathComponent("narrated-sample.mp4")
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.copyItem(at: finalURL, to: dest)
    print("NARRATION_OK -> \(dest.path) capLines=\(captions.lines.count)")
    exit(0)
} catch { print("NARRATION_FAILED \(error)"); exit(1) }
```

- [ ] **Step 3: Pre-warm Kokoro + build the probe.**

```bash
hf download aufklarer/Kokoro-82M-CoreML
xcodegen generate
xcodebuild -project Clipmunk.xcodeproj -scheme narration-probe -configuration Debug -skipMacroValidation -skipPackagePluginValidation -derivedDataPath build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 4: Run the self-test (the metallib moment of truth).**

```bash
build/Build/Products/Debug/narration-probe --selftest
```

Expected: `NARRATION_SELFTEST_OK voices=<N> synth_seconds=<~2>`. **If it fails with `Failed to load the default metallib`, do Task 5.8; otherwise skip 5.8.**

- [ ] **Step 5: Run end-to-end + eyeball.**

```bash
build/Build/Products/Debug/narration-probe ~/Downloads/<speech>.mp4 "Here is a punchy faceless narration for this clip." af_heart .context/samples
ffplay .context/samples/narrated-sample.mp4   # or open in QuickTime — confirm voiceover plays, captions track it, no black frames
```

Expected: `NARRATION_OK -> .../narrated-sample.mp4`; the file plays the synthesized voice, captions follow it, duration ≈ narration length.

- [ ] **Step 6: Commit** (if approved).

```bash
git add NarrationProbe/main.swift project.yml
git commit -m "test(tts): narration-probe (selftest + end-to-end); metallib verified at runtime"
```

### Task 5.8: (CONDITIONAL) Wire the Kokoro `mlx.metallib` build step

Only if Task 5.7 Step 4 failed with `Failed to load the default metallib`. The existing `xcodebuild` + `mlx-swift` path that serves Gemma/Marlin usually already produces it; this is the fallback.

**Files:**
- Modify: `scripts/dev-build.sh`, and the CI release workflow `.github/workflows/release.yml`

- [ ] **Step 1: Generate the metallib after package resolution.** In `scripts/dev-build.sh`, after `xcodegen generate` (line 23), add a step that runs speech-swift's script against the resolved checkout (path under the chosen `-derivedDataPath`/SPM cache) and copies `mlx.metallib` next to the built app binary. Determine the resolved checkout path first:

```bash
echo "==> building Kokoro MLX metallib"
SPEECH_DIR=$(find build -type d -path '*/checkouts/speech-swift' | head -1)
if [ -n "$SPEECH_DIR" ] && [ -f "$SPEECH_DIR/scripts/build_mlx_metallib.sh" ]; then
  ( cd "$SPEECH_DIR" && ./scripts/build_mlx_metallib.sh release ) || true
  METALLIB=$(find "$SPEECH_DIR" -name 'mlx.metallib' | head -1)
  [ -n "$METALLIB" ] && cp "$METALLIB" "$APP/Contents/Resources/" && echo "copied mlx.metallib into app bundle"
fi
```

(Place the copy AFTER `APP=...` is defined; adjust ordering.)

- [ ] **Step 2: Add a bundle verification.** After the copy, fail loudly if missing:

```bash
if [ ! -f "$APP/Contents/Resources/mlx.metallib" ]; then echo "WARNING: mlx.metallib not in bundle — Kokoro will crash"; fi
```

- [ ] **Step 3: Mirror in CI** (`.github/workflows/release.yml`): ensure the runner has the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`) and native ARM Homebrew, run the same metallib build+copy before signing, and add a guard that fails the release if `mlx.metallib` is absent from `Clipmunk.app` (so a notarized DMG can't ship broken).

- [ ] **Step 4: Re-run Task 5.7 Step 4** to confirm the self-test now passes.

- [ ] **Step 5: Commit** (if approved).

```bash
git add scripts/dev-build.sh .github/workflows/release.yml
git commit -m "build(tts): compile + bundle Kokoro mlx.metallib (dev + CI) before signing"
```

**CHECKPOINT 5:** Faceless narration synthesizes, swaps audio, reconciles duration, and re-syncs captions end-to-end via `narration-probe`; the setting + voice picker exist; the build (and DMG, if Task 5.8 ran) is green. Stop and review before Phase 6.

---

## PHASE 6 — End-to-end verification on 16 GB + docs

### Task 6.1: Full-pipeline + memory verification

- [ ] **Step 1: Full shorts run with Parakeet (default constrained path).** On a 16 GB Mac:

```bash
build/Build/Products/Debug/shorts-probe ~/Downloads/<speech>.mp4 .context/samples 3
```

Expected: Parakeet transcribes (constrained), Director finds moments, 3 samples render. Watch stderr `mlx ... peak=` lines stay within RAM (the project's ~0-swap bar). Confirm no swap via Activity Monitor / `vm_stat` during the run.

- [ ] **Step 2: Narration end-to-end** (Task 5.7 Step 5) on the same machine; confirm memory stays bounded (Kokoro loads after the Director is freed).

- [ ] **Step 3: Non-English routing.** Run on a non-English clip (or force `languageHint`) and confirm stderr shows the WhisperKit path was used (not Parakeet), preserving multilingual accuracy.

- [ ] **Step 4: Reopen persistence.** Build + launch the app (`bash scripts/dev-build.sh --open`), enable faceless voiceover, make shorts, reopen the job from History, confirm `narrationEnabled`/`narrationVoiceID` persisted and re-render identically; confirm a pre-narration job still reopens (backward-compat).

### Task 6.2: Docs, memory, license, cleanup

- [ ] **Step 1: Remove the temporary self-test blocks** added to `ShortsProbe/main.swift` in Tasks 4.1/4.3/5.3 (they were scaffolding; `narration-probe --selftest` is the permanent home). Keep the `--stt` A/B flag.

- [ ] **Step 2: Update the spec status.** In `docs/superpowers/specs/2026-06-07-lean-model-lineup-and-tts-design.md`, mark §6/§7 as shipped and note the as-built deviations (ASREngine takes `audioURL`; narration is a pre-stage via `NarrationComposer`; metallib handled by `<existing mlx-swift build / Task 5.8>`).

- [ ] **Step 3: Confirm the speech-swift license** (the spec flagged it as unverified). Check the repo's LICENSE; record it in the spec and ensure it's compatible with shipping in a signed DMG. If incompatible, STOP and escalate to the user.

- [ ] **Step 4: README + memory.** Update the README model lineup/table to include Parakeet (STT) + Kokoro (TTS faceless narration). Update the `clipmunk-lean-lineup-and-tts` memory: Phases 4–5 shipped.

- [ ] **Step 5: Final green build + commit** (if approved).

```bash
bash scripts/dev-build.sh
git add -A
git commit -m "docs(stt/tts): mark Phases 4-5 shipped; README + spec as-built; remove probe scaffolding"
```

**CHECKPOINT 6 (final):** Full pipeline runs within RAM on 16 GB with Parakeet default + WhisperKit fallback + optional Kokoro narration; persistence and non-English routing verified; docs/license updated. Decide integration via `superpowers:finishing-a-development-branch`.

---

## Open decision flagged for the user during implementation

- **Narration source text (Task 5.4 Step 2):** default is the primary caption body (`PostVariant.summary`) → hook → transcript slice. If you'd rather the voiceover read the *transcript* (what was actually said, lightly cleaned) or always the hook, change `ShortClip.narrationText`. This shapes the faceless feel (scripted promo vs. spoken-content voiceover).
