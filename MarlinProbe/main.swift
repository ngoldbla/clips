// Developer probe — NOT shipped in the app.
//
// Loadability + timestamp-fidelity spike for Marlin-2B-MLX-8bit (a Qwen3.5-2B
// video VLM with a Qwen3-VL vision tower). Marlin's `model_type` is `qwen3_5`
// and its `processor_class` is `Qwen3VLProcessor`, both already implemented in
// mlx-swift-lm — so this loads it through the *existing* `VLMModelFactory`, no
// new architecture code. It exercises the two trained modes:
//
//   caption : "Provide a spatial description of this clip followed by
//              time-ranged events." → Scene + `<start - end> desc` lines.
//   find    : "Identify the timestamps during which "<event>" takes place." →
//              "From <start> to <end>."
//
// The make-or-break question is whether the *pure-Swift MLX* path preserves the
// second-precise timestamps (the model card warns mlx-vlm's qwen3_5 path can
// compress them). This probe prints the raw spans so we can judge directly.
//
//   usage:
//     marlin-probe <video> [caption|find] [options]
//   options:
//     --event "<text>"     event to ground (find mode; required for find)
//     --start <sec>        export & feed only this sub-range (chunk test)
//     --dur <sec>          sub-range duration (default: to end)
//     --max-tokens <n>     generation cap (default: caption 2048 / find 64)
//     --model <hf-id>      override model id (default: junwatu/Marlin-2B-MLX-8bit)
//     --fps <f>            informational only; processor samples at its trained fps

import AVFoundation
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

// MARK: - Trained prompts (must match modeling_marlin.py exactly)

let CAPTION_PROMPT = """
Provide a spatial description of this clip followed by time-ranged events.
For each event, give the time range as <start - end> and a short description.
"""

func groundingPrompt(_ event: String) -> String {
    "Identify the timestamps during which \"\(event)\" takes place. "
        + "Output the time range as \"From <start> to <end>.\" (numbers in seconds)."
}

// MARK: - Tiny arg parser

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let argv = CommandLine.arguments
guard argv.count > 1 else {
    note("usage: marlin-probe <video> [caption|find] [--event ..] [--start S] [--dur D] [--max-tokens N] [--model id]")
    exit(2)
}
let videoPath = argv[1]
let mode = (argv.count > 2 && !argv[2].hasPrefix("--")) ? argv[2] : "caption"

func optValue(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
let eventArg = optValue("--event")
let startSec = optValue("--start").flatMap(Double.init)
let durSec = optValue("--dur").flatMap(Double.init)
let modelID = optValue("--model") ?? "junwatu/Marlin-2B-MLX-8bit"
let maxTokens = optValue("--max-tokens").flatMap(Int.init) ?? (mode == "find" ? 64 : 1024)
let repPenalty = optValue("--rep-penalty").flatMap(Float.init) ?? 1.1
let temp = optValue("--temp").flatMap(Float.init) ?? 0.0
// Per-frame resize (square px on a side). 448 ≈ Marlin's trained VIDEO_MAX_PIXELS
// (200704) — on-distribution and ~25% fewer vision tokens than the 512 default.
let resize = optValue("--resize").flatMap { Double($0) } ?? 448

// MARK: - MLX allocator (mirror MemoryPolicy for a 16 GB Mac)

let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
let constrained = ramGB < 24
MLX.Memory.cacheLimit = (constrained ? 256 : 1024) * 1024 * 1024
if constrained {
    MLX.Memory.memoryLimit = max(8, ramGB - 6) * 1024 * 1024 * 1024
}
note("[marlin] RAM \(ramGB)GB constrained=\(constrained) — mode=\(mode) model=\(modelID) maxTokens=\(maxTokens)")

// MARK: - Optional sub-range export (chunk timestamp test)

/// Exports [start, start+dur] of the source video to a temp .mp4 so we can feed
/// Marlin a bounded window — both to stay inside the trained frame budget and to
/// test that emitted timestamps are CHUNK-RELATIVE (which is what lets us offset
/// them to absolute video time in the real pipeline).
func exportSubRange(_ src: URL, start: Double, dur: Double?) async throws -> URL {
    let asset = AVURLAsset(url: src)
    let total = try await asset.load(.duration).seconds
    let length = dur ?? (total - start)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("marlin-chunk-\(Int(start))-\(Int(length)).mp4")
    try? FileManager.default.removeItem(at: out)
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
        throw NSError(domain: "marlin", code: 1, userInfo: [NSLocalizedDescriptionKey: "no export session"])
    }
    let t0 = CMTime(seconds: start, preferredTimescale: 600)
    let t1 = CMTime(seconds: start + length, preferredTimescale: 600)
    export.timeRange = CMTimeRange(start: t0, end: t1)
    try await export.export(to: out, as: .mp4)
    note(String(format: "[marlin] exported chunk [%.1f, %.1f]s → %@", start, start + length, out.lastPathComponent))
    return out
}

do {
    var feedURL = URL(fileURLWithPath: videoPath)
    if let s = startSec {
        feedURL = try await exportSubRange(feedURL, start: s, dur: durSec)
    }

    // MARK: - Load Marlin via the existing VLM factory

    note("[marlin] resolving weights (first run downloads ~2.7 GB)…")
    let downloader = #hubDownloader()
    let localDir = try await downloader.download(
        id: modelID,
        revision: nil,
        matching: ["*.safetensors", "*.json", "*.txt", "*.jinja"],
        useLatest: false,
        progressHandler: { progress in
            let f = Int(progress.fractionCompleted * 100)
            FileHandle.standardError.write(Data("\r[marlin] download \(f)%   ".utf8))
        })
    note("\n[marlin] weights at \(localDir.path)")

    note("[marlin] loading container via VLMModelFactory…")
    let loadStart = Date()
    let container = try await VLMModelFactory.shared.loadContainer(
        from: localDir, using: #huggingFaceTokenizerLoader())
    note(String(format: "[marlin] container loaded in %.1fs — %@",
                Date().timeIntervalSince(loadStart),
                "mlx active=\(MLX.Memory.activeMemory / 1_048_576)MB peak=\(MLX.Memory.peakMemory / 1_048_576)MB"))

    // MARK: - Generate

    let prompt: String
    switch mode {
    case "find":
        guard let event = eventArg, !event.isEmpty else {
            note("[marlin] find mode requires --event \"...\""); exit(2)
        }
        prompt = groundingPrompt(event)
    default:
        prompt = CAPTION_PROMPT
    }

    // Marlin trains with greedy (do_sample=False), but pure-MLX greedy on a 2B
    // loops on low-variety video; a mild repetition penalty breaks the loop while
    // keeping decoding near-greedy.
    let params = GenerateParameters(
        maxTokens: maxTokens, temperature: temp, repetitionPenalty: repPenalty)
    note("[marlin] decode: temp=\(temp) repPenalty=\(repPenalty) maxTokens=\(maxTokens) resize=\(Int(resize))")
    let session = ChatSession(
        container, instructions: nil, generateParameters: params,
        processing: .init(resize: CGSize(width: resize, height: resize)))

    note("[marlin] generating (\(mode))…")
    var raw = ""
    let genStart = Date()
    var firstTokenAt: Date?
    for try await chunk in session.streamResponse(to: prompt, videos: [.url(feedURL)]) {
        if firstTokenAt == nil { firstTokenAt = Date() }
        raw += chunk
    }
    let end = Date()
    let prefillS = (firstTokenAt ?? end).timeIntervalSince(genStart)
    let genS = max(0.001, end.timeIntervalSince(firstTokenAt ?? genStart))
    let tokS = (Double(raw.count) / 4.0) / genS

    print("\n──── RAW MARLIN OUTPUT (\(mode)) ────")
    print(raw)
    print("──── END RAW ────")
    note(String(format: "[marlin] prefill %.1fs, gen %.1fs, ~%.0f tok/s, %d chars",
                prefillS, genS, tokS, raw.count))
    note("[marlin] " + "mlx active=\(MLX.Memory.activeMemory / 1_048_576)MB peak=\(MLX.Memory.peakMemory / 1_048_576)MB")

    // Light parse so we can eyeball the spans (full parser lives in the app later).
    let offset = startSec ?? 0
    let cleaned = raw
        .replacingOccurrences(of: "<think>", with: "")
        .replacingOccurrences(of: "</think>", with: "")
    if mode == "find" {
        if let m = cleaned.range(of: #"From\s+(\d+\.?\d*)\s*(?:s|sec)?\s+to\s+(\d+\.?\d*)"#,
                                 options: .regularExpression) {
            note("[marlin] grounded span (chunk-relative): \(cleaned[m])  → absolute += \(offset)s")
        } else {
            note("[marlin] ⚠️ no 'From X to Y' span parsed")
        }
    } else {
        let re = try! NSRegularExpression(
            pattern: #"<?\s*(\d+\.?\d*)\s*-\s*(\d+\.?\d*)\s*>?\s*[:\-]?\s*(.+)"#)
        var count = 0
        for line in cleaned.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            let r = NSRange(s.startIndex..., in: s)
            guard let m = re.firstMatch(in: s, range: r),
                  let r1 = Range(m.range(at: 1), in: s),
                  let r2 = Range(m.range(at: 2), in: s),
                  let r3 = Range(m.range(at: 3), in: s),
                  let a = Double(s[r1]), let b = Double(s[r2]), b > a else { continue }
            count += 1
            note(String(format: "[marlin] event %2d: <%.1f - %.1f> (abs %.1f-%.1f)  %@",
                        count, a, b, a + offset, b + offset, String(s[r3]).trimmingCharacters(in: .whitespaces)))
        }
        note("[marlin] parsed \(count) time-ranged event(s)")
        if count == 0 { note("[marlin] ⚠️ no events parsed — caption format mismatch or empty") }
    }

    if startSec != nil { try? FileManager.default.removeItem(at: feedURL) }
} catch {
    note("\n[marlin] ❌ FAILED: \(error)")
    exit(1)
}
