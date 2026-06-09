import AVFoundation
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

/// The perception layer: Marlin-2B (a Qwen3.5-2B video VLM) watches the video
/// and produces a timestamped "what is on screen, when" track that is merged
/// into the Director's transcript — so the moment-finder can see, not just read.
///
/// Marlin's `model_type` is `qwen3_5` and its processor is `Qwen3VLProcessor`,
/// both already in mlx-swift-lm, so it loads through the *same* `VLMModelFactory`
/// the Qwen Director uses — no custom architecture. The forward pass is stock
/// Qwen3.5; only the trained prompt + output parsing are Marlin-specific
/// (`MarlinCaptionParser`).
///
/// The high-value signal is Marlin's **Scene** paragraph: it reads on-screen
/// text, names B-roll, and orders the visual narrative. Long videos are processed
/// in bounded **windows** (Marlin trains at 2 fps with a ~240-frame budget, and
/// the Swift Qwen3-VL sampler is hardwired to 2 fps over the whole input — so a
/// long clip would exceed the budget and rescale time, corrupting timestamps).
/// We cut ≤`windowSeconds` windows, caption each, and offset chunk-local spans
/// back to absolute video time.
@MainActor
@Observable
final class VisualMapper {

    enum Phase: Equatable {
        case idle
        case downloading(fraction: Double)
        case loading
        case mapping(fraction: Double)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var container: ModelContainer?

    /// Marlin-2B, 8-bit MLX (~2.5 GB resident). Overridable for A/B via env in DEBUG.
    nonisolated static let defaultModelID = "junwatu/Marlin-2B-MLX-8bit"

    /// Window/decode knobs, tuned on the sample video for a 16 GB M1:
    /// - `windowSeconds` 45: vision-token attention is ~quadratic, so per-window
    ///   cost explodes once activations cross the ~10 GB `memoryLimit` soft cap
    ///   (30 s peaks ~6 GB and is fast; 90 s exceeds the cap and throttles ~10×).
    ///   45 s stays under the cap while keeping windows few and scenes coherent.
    /// - `resize` 448 ≈ Marlin's trained VIDEO_MAX_PIXELS (200704): on-distribution
    ///   and ~25% fewer vision tokens than the 512 default → faster, less memory.
    /// - `maxTokensPerWindow` 350 captures the Scene paragraph (emitted first) and
    ///   stops before the model's low-variety event loop wastes time.
    /// - `repetitionPenalty` 1.12 breaks pure-MLX greedy degeneration.
    struct Config: Sendable {
        var windowSeconds: Double = 45
        var resize: Double = 448
        var maxTokensPerWindow: Int = 350
        var repetitionPenalty: Float = 1.12

        /// DEBUG env overrides for the closed-loop duration/quality A/B.
        static func resolved() -> Config {
            var c = Config()
            #if DEBUG
            let env = ProcessInfo.processInfo.environment
            if let v = env["CLIPMUNK_VISION_WINDOW"], let d = Double(v) { c.windowSeconds = d }
            if let v = env["CLIPMUNK_VISION_RESIZE"], let d = Double(v) { c.resize = d }
            if let v = env["CLIPMUNK_VISION_MAXTOK"], let n = Int(v) { c.maxTokensPerWindow = n }
            if let v = env["CLIPMUNK_VISION_REP"], let f = Float(v) { c.repetitionPenalty = f }
            #endif
            return c
        }
    }

    var isReady: Bool { container != nil }
    var isBusy: Bool {
        switch phase {
        case .downloading, .loading, .mapping: return true
        default: return false
        }
    }

    // MARK: - Lifecycle

    /// Downloads (if needed) and loads Marlin. Lazy — only when a vision pass runs.
    /// Throws on download/load failure so the (mandatory) caller can abort loudly
    /// instead of running a blind Director.
    func prepareIfNeeded() async throws {
        guard container == nil, !isBusy else { return }
        phase = .downloading(fraction: 0)
        do {
            // Marlin-2B is a gated HF repo (gated=auto) → needs a read token.
            let downloader = ClipmunkModelDownloader(token: HFToken.resolve())
            let localDir = try await downloader.download(
                id: Self.effectiveModelID,
                revision: nil,
                matching: ["*.safetensors", "*.json", "*.txt", "*.jinja"],
                useLatest: false,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        let f = progress.fractionCompleted
                        self.phase = f < 1.0 ? .downloading(fraction: f) : .loading
                    }
                })
            phase = .loading
            container = try await VLMModelFactory.shared.loadContainer(
                from: localDir, using: #huggingFaceTokenizerLoader())
            phase = .ready
            Self.log("loaded: Marlin-2B (\(Self.effectiveModelID))")
        } catch {
            Self.log("load FAILED: \(error)")
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Frees Marlin and its Metal cache so the Director can load on a 16 GB Mac.
    func unload() {
        container = nil
        phase = .idle
        MLX.Memory.clearCache()
    }

    // MARK: - Perception pass

    /// Watches the whole video window-by-window and returns the absolute-time
    /// visual timeline. Never throws on empty output — returns `.empty` so the
    /// caller can always fall back to a transcript-only Director.
    func mapVideo(url: URL, config: Config = .resolved()) async throws -> VisualTimeline {
        guard let container else { throw VisualMapperError.notReady }
        let asset = AVURLAsset(url: url)
        let total = try await asset.load(.duration).seconds
        guard total > 0 else { return .empty }

        let window = max(15, config.windowSeconds)
        var windows: [VisualWindow] = []
        var windowStart = 0.0

        while windowStart < total - 0.5 {
            try Task.checkCancellation()
            let dur = min(window, total - windowStart)
            phase = .mapping(fraction: windowStart / total)

            let chunkURL = try await Self.exportWindow(asset, start: windowStart, dur: dur)
            defer { try? FileManager.default.removeItem(at: chunkURL) }

            let started = Date()
            let raw = try await caption(videoURL: chunkURL, config: config)
            let (scene, local) = MarlinCaptionParser.parseCaption(raw)

            // Offset chunk-local spans to absolute time; clamp to the window so a
            // hallucinated out-of-range end can't bleed past the chunk.
            var events: [VisualEvent] = []
            for e in local {
                let s = e.start + windowStart
                let en = min(e.end + windowStart, windowStart + dur + 0.5)
                guard en > s else { continue }
                events.append(VisualEvent(start: s, end: en, text: e.text))
            }
            events = Self.collapseRuns(events)

            windows.append(VisualWindow(
                start: windowStart, end: windowStart + dur, scene: scene, events: events))
            Self.log(String(format: "window [%@-%@] scene=%dch events=%d in %.1fs",
                            Self.mmss(windowStart), Self.mmss(windowStart + dur),
                            scene.count, events.count, Date().timeIntervalSince(started)))
            windowStart += dur
        }

        phase = .ready
        let timeline = VisualTimeline(windows: windows)
        Self.log("mapVideo: \(windows.count) window(s), \(timeline.allEvents.count) event(s) over \(Int(total))s")
        return timeline
    }

    /// One caption call over a single (already-bounded) video window. Fresh
    /// session per call so windows never share KV. Greedy + mild repetition
    /// penalty; resize matches Marlin's trained pixel budget.
    private func caption(videoURL: URL, config: Config) async throws -> String {
        guard let container else { throw VisualMapperError.notReady }
        let params = GenerateParameters(
            maxTokens: config.maxTokensPerWindow,
            temperature: 0.0,
            repetitionPenalty: config.repetitionPenalty)
        let session = ChatSession(
            container, instructions: nil, generateParameters: params,
            processing: .init(resize: CGSize(width: config.resize, height: config.resize)))
        var raw = ""
        for try await chunk in session.streamResponse(
            to: MarlinCaptionParser.captionPrompt, videos: [.url(videoURL)]
        ) {
            raw += chunk
        }
        return raw
    }

    // MARK: - Helpers

    /// Exports [start, start+dur] to a temp .mp4 (re-encoded 720p) so Marlin sees
    /// a bounded window. Re-encode (not passthrough) guarantees a clean, seekable
    /// clip regardless of source GOP structure.
    static func exportWindow(_ asset: AVURLAsset, start: Double, dur: Double) async throws -> URL {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipmunk-vision-\(UUID().uuidString).mp4")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            throw VisualMapperError.exportFailed
        }
        let t0 = CMTime(seconds: start, preferredTimescale: 600)
        let t1 = CMTime(seconds: start + dur, preferredTimescale: 600)
        export.timeRange = CMTimeRange(start: t0, end: t1)
        do {
            try await export.export(to: out, as: .mp4)
        } catch {
            // Don't leave a partial temp clip behind on a 16 GB machine.
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    /// Collapses runs of near-identical consecutive events (the low-variety
    /// "talking head" cadence) into one merged span, so the timeline keeps only
    /// distinct visual beats.
    static func collapseRuns(_ events: [VisualEvent]) -> [VisualEvent] {
        var out: [VisualEvent] = []
        for e in events.sorted(by: { $0.start < $1.start }) {
            if var last = out.last, similar(last.text, e.text), e.start <= last.end + 0.6 {
                last.end = max(last.end, e.end)
                out[out.count - 1] = last
            } else {
                out.append(e)
            }
        }
        return out
    }

    /// Two event descriptions count as the same beat if their normalized text
    /// matches on the first several words (tolerates "speaks/gestures" variants).
    private static func similar(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            s.lowercased().split(whereSeparator: { !$0.isLetter }).prefix(4).joined(separator: " ")
        }
        return key(a) == key(b)
    }

    static func mmss(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[clipmunk/vision] \(message)\n".utf8))
    }

    /// DEBUG model override for the closed-loop A/B (e.g. a different Marlin build).
    nonisolated static var effectiveModelID: String {
        #if DEBUG
        if let o = ProcessInfo.processInfo.environment["CLIPMUNK_VISION_MODEL"], !o.isEmpty {
            return o
        }
        #endif
        return defaultModelID
    }
}

enum VisualMapperError: LocalizedError {
    case notReady
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .notReady: return "The vision model is still loading."
        case .exportFailed: return "Couldn't prepare a video window for the vision pass."
        }
    }
}

// MARK: - Merge into the Director's transcript

extension Transcript {
    /// Weaves the visual timeline into the `[MM:SS] text` transcript the Director
    /// reads: at each window's start it inserts an `ON-SCREEN` line carrying
    /// Marlin's Scene paragraph (and any distinct event beats), so the
    /// moment-finder can reason over what's shown, not just what's said. Falls
    /// back to the plain transcript when the timeline is empty.
    func augmented(with timeline: VisualTimeline) -> String {
        guard !timeline.isEmpty else { return srtLike() }

        struct Line { let t: Double; let order: Int; let text: String }
        var lines: [Line] = []

        // order 1 = speech, order 0 = the window's visual header (so the visual
        // context for a time appears just before the speech at that time).
        for seg in segments {
            lines.append(Line(t: seg.start, order: 1,
                              text: "[\(Self.stamp(seg.start))] \(seg.text.trimmed)"))
        }
        for w in timeline.windows where !(w.scene.isEmpty && w.events.isEmpty) {
            let scene = w.scene.trimmed
            var block = "[\(Self.stamp(w.start))-\(Self.stamp(w.end))] 👁 ON-SCREEN:"
            if !scene.isEmpty { block += " \(scene)" }
            let beats = w.events.prefix(6)
                .map { "    • \(Self.stamp($0.start))-\(Self.stamp($0.end)) \($0.text.trimmed)" }
            if !beats.isEmpty { block += "\n" + beats.joined(separator: "\n") }
            lines.append(Line(t: w.start, order: 0, text: block))
        }

        return lines
            .sorted { $0.t != $1.t ? $0.t < $1.t : $0.order < $1.order }
            .map(\.text)
            .joined(separator: "\n")
    }

    private static func stamp(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
