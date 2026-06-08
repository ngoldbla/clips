import AVFoundation
import Foundation

// Developer-only headless narration probe: synthesize (Kokoro) + audio-swap +
// duration-reconcile + reframe/captions on a real clip, writing a faceless
// sample .mp4. `--selftest` runs voice enumeration + a REAL Kokoro synthesize
// (the metallib moment of truth) + the pure compose helpers, with no pipeline.
//
// usage: narration-probe --selftest
//        narration-probe <video> <script-text> [voice=af_heart] [outDir=.context/samples]

func note(_ m: String) { FileHandle.standardError.write(Data("[narration-probe] \(m)\n".utf8)) }

// --selftest: voice enumeration + a real Kokoro synthesize + compose, no pipeline.
if CommandLine.arguments.contains("--selftest") {
    let voices = VoiceCatalog.installed()
    note("installed voices: \(voices.count) — \(voices.prefix(5).map(\.id).joined(separator: ", "))…")
    do {
        let samples = try await NarrationService.shared.synthesize(
            text: "This is a Clipmunk narration test.", voiceID: VoiceCatalog.defaultVoiceID)
        let seconds = Double(samples.count) / NarrationService.sampleRate
        precondition(seconds > 0.5, "synthesized < 0.5s")
        // Reconcile against a synthetic 1s clip-less check is skipped; the compose
        // helper is exercised in the end-to-end path below.
        print("NARRATION_SELFTEST_OK voices=\(voices.count) synth_seconds=\(String(format: "%.2f", seconds))")
        exit(0)
    } catch {
        // If this prints "Failed to load the default metallib", do Task 5.8.
        print("NARRATION_SELFTEST_FAILED \(error)"); exit(1)
    }
}

// End-to-end: synthesize from a provided script and render a faceless sample.
let args = CommandLine.arguments
guard args.count > 2 else {
    print("usage: narration-probe <video> <script-text> [voice=af_heart] [outDir=.context/samples]"); exit(1)
}
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
