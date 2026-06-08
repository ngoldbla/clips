import Foundation

// Headless end-to-end shorts pipeline — the real app path without the GUI:
// transcribe (WhisperKit) → Gemma 4 E2B finds moments + writes captions → cut
// each clip → reframe 9:16 + burn animated captions + hook (VerticalReframer).
// Writes finished sample .mp4s so the output can be reviewed without driving the
// app (whose SwiftUI scene won't run headlessly).
//
// usage: shorts-probe <video> [outDir=.context/samples] [maxClips=3]

func note(_ m: String) { FileHandle.standardError.write(Data("[shorts-probe] \(m)\n".utf8)) }
func elapsed(_ t: Date) -> String { String(format: "%.1fs", Date().timeIntervalSince(t)) }
func slug(_ s: String) -> String {
    let base = s.lowercased()
        .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return String((base.isEmpty ? "clip" : base).prefix(32))
}

// TEMP self-test for AudioResampler (Task 4.1). Run: shorts-probe --selftest-resampler <anyAudioOrVideo>
if CommandLine.arguments.contains("--selftest-resampler") {
    guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) else {
        print("usage: shorts-probe --selftest-resampler <audio-or-video>"); exit(1)
    }
    do {
        let samples = try AudioResampler.pcm16kMono(from: URL(fileURLWithPath: path))
        let seconds = Double(samples.count) / 16000.0
        precondition(!samples.isEmpty, "resampler returned no samples")
        precondition(seconds > 0.1, "resampler produced < 0.1s of audio")
        print("RESAMPLER_OK samples=\(samples.count) seconds=\(String(format: "%.2f", seconds))")
        exit(0)
    } catch { print("RESAMPLER_FAILED \(error)"); exit(1) }
}

if CommandLine.arguments.contains("--selftest-segments") {
    let utts = ["Hello there friend", "this is a test"]
    let segs = ParakeetSegmenter.segmentize(utterances: utts, totalDuration: 10)
    precondition(segs.count == 2, "expected 2 segments, got \(segs.count)")
    precondition(segs[0].start == 0, "first segment must start at 0")
    precondition(abs(segs.last!.end - 10) < 0.001, "last segment must end at totalDuration")
    precondition(segs[1].start >= segs[0].end - 0.001 && segs[1].start <= segs[0].end + 0.001,
                 "segments must be contiguous")
    precondition(segs[0].words.isEmpty, "Parakeet segments carry no word stamps (synthesized later)")
    precondition((segs[0].end - segs[0].start) > (segs[1].end - segs[1].start),
                 "longer utterance should get a longer span")
    print("SEGMENTS_OK \(segs.map { String(format: "%.2f-%.2f", $0.start, $0.end) })")
    exit(0)
}

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: shorts-probe <video> [outDir] [maxClips]"); exit(1) }
let videoURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : ".context/samples")
let maxClips = args.count > 3 ? (Int(args[3]) ?? 3) : 3
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

MemoryPolicy.configureMLX()
let t0 = Date()

do {
    // 1. Transcribe (WhisperKit; cache is already warm).
    let transcription = await TranscriptionService()
    let transcript = try await transcription.transcript(for: videoURL, languageHint: "English")
    let words = transcript.segments.reduce(0) { $0 + $1.words.count }
    note("transcript: \(transcript.segments.count) segments, \(words) word-stamps, lang=\(transcript.language ?? "?") in \(elapsed(t0))")
    if MemoryPolicy.shouldFreeASRAfterTranscribe { transcription.unload() }
    MemoryPolicy.releaseCaches()

    // 2. Director (Gemma 4 E2B): moments + inline 3-platform captions.
    let director = await MomentFinderService()
    await director.prepareIfNeeded()
    guard await director.isReady else { print("DIRECTOR_LOAD_FAILED phase=\(await director.phase)"); exit(2) }
    let candidates = try await director.findMoments(
        transcript: transcript.srtLike(), includeCaptions: true,
        language: "English", styleExamples: "")
    note("found \(candidates.count) clips in \(elapsed(t0))")
    director.unload()
    MemoryPolicy.releaseCaches()

    // 3+4. Cut + render the top N (reframe 9:16 + animated captions + hook).
    let style = CaptionStyle.default
    var made: [String] = []
    for (i, c) in candidates.prefix(maxClips).enumerated() {
        let tc = Date()
        let cutURL = try await MediaExtractor.cutClip(from: videoURL, start: c.start, duration: c.duration)
        let stamps = transcript.wordStamps(start: c.start, end: c.end)
        let script = CaptionScript.build(words: stamps, clipStart: c.start, clipEnd: c.end)
        let landscape = await VerticalReframer.isLandscape(url: cutURL)
        let overlay = c.overlay.isEmpty ? c.hook : c.overlay
        let dest = outDir.appendingPathComponent(String(format: "sample-%d-%@.mp4", i + 1, slug(c.hook)))
        try? FileManager.default.removeItem(at: dest)
        do {
            let rendered = try await VerticalReframer.process(
                clipURL: cutURL, reframe: landscape, overlayText: overlay,
                captionScript: script, captionStyle: style)
            let finalURL = rendered ?? cutURL
            try FileManager.default.copyItem(at: finalURL, to: dest)
            if let rendered, rendered != cutURL { try? FileManager.default.removeItem(at: rendered) }
            note("clip \(i + 1): \(c.rangeLabel) reframed=\(landscape) capLines=\(script.lines.count) -> \(dest.lastPathComponent) in \(elapsed(tc))")
        } catch {
            // Burn-in failed (e.g. offline Core Animation) — keep the raw cut so a
            // sample still exists; reported honestly.
            try? FileManager.default.copyItem(at: cutURL, to: dest)
            note("clip \(i + 1): RENDER FAILED (\(error)) — saved raw cut \(dest.lastPathComponent)")
        }
        try? FileManager.default.removeItem(at: cutURL)
        made.append(dest.lastPathComponent)
    }
    print("SHORTS_OK clips=\(made.count) dir=\(outDir.path) total=\(elapsed(t0))")
    made.forEach { print("  \($0)") }
    exit(0)
} catch {
    print("SHORTS_FAILED \(error)")
    exit(3)
}
