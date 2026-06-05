// Developer probe — NOT shipped in the app.
//
// Runs Clipmunk's real on-device generation path (MediaExtractor → Gemma4Engine
// → JSONVariantParser) on a single video, from the command line, so the
// pipeline can be verified headlessly without driving the SwiftUI app.
//
//   usage: clipmunk-probe <video-path> [coach-md-path]

import Foundation
import Gemma4Swift

let args = CommandLine.arguments
let videoPath = args.count > 1 ? args[1] : "build/test-clip.mp4"
let coachPath = args.count > 2 ? args[2] : "Clipmunk/Resources/social-content-coach.md"
let videoURL = URL(fileURLWithPath: videoPath)

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

do {
    let job = try await MediaExtractor.makeJob(from: videoURL)
    note("• video: \(job.fileName)  (\(job.durationLabel))")

    note("• extracting audio track…")
    let audioURL = try await MediaExtractor.extractAudio(from: videoURL)
    note("  audio: \(audioURL?.lastPathComponent ?? "none")")

    note("• preparing Gemma 4 E4B (first run downloads ~5 GB)…")
    let engine = try await Gemma4Engine.prepare(model: .e4b4bit) { stage in
        switch stage {
        case .downloading(let progress):
            FileHandle.standardError.write(
                Data("\r  download \(Int(progress.fraction * 100))%  \(progress.formattedProgress)   ".utf8))
        case .loading:
            FileHandle.standardError.write(Data("\n  loading model into memory…\n".utf8))
        }
    }
    note("• model ready — running multimodal generation…")

    let coach = (try? String(contentsOfFile: coachPath, encoding: .utf8)) ?? ""
    note("  coach document: \(coach.isEmpty ? "MISSING" : "\(coach.count) chars")")
    let prompt = PromptBuilder.buildPrompt(coach: coach, languageOverride: "", styleExamples: "")

    let media = Gemma4Engine.MediaInput(videoURL: videoURL, audioURL: audioURL)
    let started = Date()
    let raw = try await engine.describe(media: media, prompt: prompt)
    note("• generation took \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

    print("\n──── RAW MODEL OUTPUT ────")
    print(raw)
    print("──── END RAW ────\n")

    let result = try JSONVariantParser.parse(raw)
    print("✅ parsed OK — language: \(result.detectedLanguage ?? "unknown")")
    for variant in result.variants {
        print("\n[\(variant.platform.displayName)]")
        print("  hook:    \(variant.hook)")
        print("  caption: \(variant.summary)")
        print("  tags:    \(variant.hashtagLine)")
    }

    if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
} catch {
    note("\n❌ FAILED: \(error)")
    exit(1)
}
