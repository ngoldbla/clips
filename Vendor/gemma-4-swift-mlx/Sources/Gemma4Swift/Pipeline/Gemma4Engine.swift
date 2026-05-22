//  Gemma4Engine.swift
//
//  Added by the Shortcast project — NOT part of upstream gemma-4-swift-mlx
//  (https://github.com/VincentGourbin/gemma-4-swift-mlx). Covered by the same
//  MIT License as the rest of this package.
//
//  A small, app-facing facade over the lower-level Gemma 4 multimodal stack.
//  It wraps model download + load and a one-shot multimodal generation behind
//  an opaque handle, so a host application only needs to `import Gemma4Swift`.
//  The generation path mirrors the proven recipe in `Gemma4CLI`'s `describe`
//  subcommand (placeholder expansion + pending-media injection + decode loop).

import CoreGraphics
import Foundation
import MLX
import MLXRandom
@preconcurrency import MLXLMCommon

public final class Gemma4Engine: @unchecked Sendable {

    /// Progress stages emitted while preparing the model.
    public enum Stage: Sendable {
        case downloading(Gemma4DownloadProgress)
        case loading
    }

    /// Multimodal inputs for a single generation.
    public struct MediaInput: Sendable {
        public var videoURL: URL?
        public var audioURL: URL?
        public var imageURLs: [URL]
        /// Frames sampled from the video (~1 fps, capped). Lower keeps latency down.
        public var videoMaxFrames: Int

        public init(videoURL: URL? = nil,
                    audioURL: URL? = nil,
                    imageURLs: [URL] = [],
                    videoMaxFrames: Int = 16) {
            self.videoURL = videoURL
            self.audioURL = audioURL
            self.imageURLs = imageURLs
            self.videoMaxFrames = videoMaxFrames
        }
    }

    /// Soft tokens emitted per still image (Gemma 4 reference value).
    private static let imageSoftTokens = 280

    public let model: Gemma4Pipeline.Model
    private let container: ModelContainer

    private init(model: Gemma4Pipeline.Model, container: ModelContainer) {
        self.model = model
        self.container = container
    }

    // MARK: - Preparation

    /// Ensures the model weights are on disk (downloading if needed) and loads
    /// the full multimodal model (vision + audio) into memory.
    public static func prepare(
        model: Gemma4Pipeline.Model = .e4b4bit,
        hfToken: String? = nil,
        onStage: (@Sendable (Stage) -> Void)? = nil
    ) async throws -> Gemma4Engine {
        if !Gemma4ModelCache.isDownloaded(model) {
            _ = try await Gemma4ModelDownloader.download(model, token: hfToken) { progress in
                onStage?(.downloading(progress))
            }
        }
        guard let path = Gemma4ModelCache.localPath(for: model) else {
            throw Gemma4PipelineError.modelNotDownloaded(model.rawValue)
        }
        onStage?(.loading)
        await Gemma4Registration.register(multimodal: true)
        let container = try await loadModelContainer(from: path, using: Gemma4TokenizerLoader())
        return Gemma4Engine(model: model, container: container)
    }

    // MARK: - Generation

    /// Runs a single multimodal generation: feeds video frames + audio + a text
    /// prompt and returns the full decoded response. Heavy work runs on the
    /// model's own actor, not the caller's.
    public func describe(
        media: MediaInput,
        prompt: String,
        maxTokens: Int = 1400,
        temperature: Float = 0.2,
        onToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {

        // 1. Pre-process media (frame sampling, mel spectrogram) off the model actor.
        var videoFrames: Gemma4VideoProcessor.VideoFrames?
        if let videoURL = media.videoURL {
            videoFrames = try await Gemma4VideoProcessor.processVideo(
                url: videoURL, maxFrames: media.videoMaxFrames)
        }
        var audioFeatures: Gemma4AudioProcessor.AudioFeatures?
        if let audioURL = media.audioURL {
            audioFeatures = try await Gemma4AudioProcessor.processAudio(url: audioURL)
        }
        var imagePixels: [MLXArray] = []
        for imageURL in media.imageURLs {
            imagePixels.append(try Gemma4ImageProcessor.processImage(url: imageURL))
        }

        // 2. Build the content string with one placeholder per modality unit.
        var parts: [String] = []
        for _ in imagePixels { parts.append(Gemma4Processor.imageToken) }
        if let vf = videoFrames {
            for i in 0 ..< vf.frameCount {
                let stamp = Gemma4VideoProcessor.formatTimestamp(vf.timestamps[i])
                parts.append("\(stamp)\n\(Gemma4Processor.videoToken)")
            }
        }
        if let af = audioFeatures, af.numTokens > 0 {
            parts.append(Gemma4Processor.audioToken)
        }
        parts.append(prompt)
        let content = parts.joined(separator: "\n")

        // 3. Tokenize via the chat template, then expand modality placeholders.
        let messages: [[String: String]] = [["role": "user", "content": content]]
        let baseTokens: [Int] = try await container.perform { context in
            try context.tokenizer.applyChatTemplate(messages: messages)
        }
        let expanded = Self.expandModalityTokens(
            baseTokens,
            imageCount: imagePixels.count,
            videoSoftTokens: videoFrames?.softTokensPerFrame ?? 0,
            audioTokens: audioFeatures?.numTokens ?? 0)

        // 4. Stack image pixel values (video frames already come stacked).
        let pixelValues = Self.batchImagePixels(imagePixels)

        // 5. Inject media + run the decode loop on the model actor.
        nonisolated(unsafe) let inPixels = pixelValues
        nonisolated(unsafe) let inVideo = videoFrames?.pixelValues
        let inVideoSoftTokens = videoFrames?.softTokensPerFrame
        nonisolated(unsafe) let inAudioFeatures = audioFeatures?.features
        nonisolated(unsafe) let inAudioMask = audioFeatures?.mask
        nonisolated(unsafe) let inputIds = MLXArray(expanded.map { Int32($0) })
        let maxTok = maxTokens
        let temp = temperature
        let tokenCallback = onToken

        return try await container.perform { context in
            if let mm = context.model as? Gemma4MultimodalLLMModel {
                mm.pendingPixelValues = inPixels
                if let inVideo {
                    mm.pendingVideoFrames = inVideo
                    mm.pendingVideoSoftTokensPerFrame = inVideoSoftTokens
                }
                if let inAudioFeatures {
                    mm.pendingAudioFeatures = inAudioFeatures
                    mm.pendingAudioMask = inAudioMask
                }
            }

            let params = GenerateParameters(maxTokens: maxTok, temperature: temp, topP: 0.95)
            let cache = context.model.newCache(parameters: params)

            // Prefill the full multimodal prompt.
            let prefill = context.model(inputIds.reshaped(1, -1), cache: cache)
            var next = argMax(prefill[0..., prefill.dim(1) - 1, 0...], axis: -1).item(Int32.self)

            var generated: [Int] = []
            for _ in 0 ..< maxTok {
                generated.append(Int(next))
                if let tokenCallback {
                    tokenCallback(context.tokenizer.decode(tokenIds: [Int(next)]))
                }
                if Gemma4Processor.eosTokenIds.contains(next) { break }

                let stepInput = MLXArray([next]).reshaped(1, 1)
                let logits = context.model(stepInput, cache: cache)[0..., 0, 0...]
                if temp <= 0.01 {
                    next = argMax(logits, axis: -1).item(Int32.self)
                } else {
                    let scaled = logits / temp
                    next = MLXRandom.categorical(log(softmax(scaled, axis: -1))).item(Int32.self)
                }
            }
            // Decode the whole sequence at once to avoid splitting multi-byte glyphs.
            return context.tokenizer.decode(tokenIds: generated)
        }
    }

    // MARK: - Helpers

    /// Replaces each single modality placeholder with the run of soft tokens the
    /// model expects, bracketed by begin/end-of-image / begin/end-of-audio tokens.
    private static func expandModalityTokens(
        _ tokens: [Int], imageCount: Int, videoSoftTokens: Int, audioTokens: Int
    ) -> [Int] {
        let imageId = Int(Gemma4Processor.imageTokenId)
        let videoId = Int(Gemma4Processor.videoTokenId)
        let audioId = Int(Gemma4Processor.audioTokenId)
        let boi = Int(Gemma4Processor.boiTokenId)
        let eoi = Int(Gemma4Processor.eoiTokenId)
        let boa = Int(Gemma4Processor.boaTokenId)
        let eoa = Int(Gemma4Processor.eoaTokenId)

        var out: [Int] = []
        out.reserveCapacity(tokens.count + imageCount * imageSoftTokens + 256)
        for token in tokens {
            switch token {
            case imageId:
                out.append(boi)
                out.append(contentsOf: repeatElement(imageId, count: imageSoftTokens))
                out.append(eoi)
            case videoId:
                out.append(boi)
                out.append(contentsOf: repeatElement(videoId, count: videoSoftTokens))
                out.append(eoi)
            case audioId:
                out.append(boa)
                out.append(contentsOf: repeatElement(audioId, count: audioTokens))
                out.append(eoa)
            default:
                out.append(token)
            }
        }
        return out
    }

    /// Pads images to a common size and concatenates them into a single batch.
    private static func batchImagePixels(_ images: [MLXArray]) -> MLXArray? {
        guard let first = images.first else { return nil }
        if images.count == 1 { return first }
        let maxH = images.map { $0.dim(2) }.max()!
        let maxW = images.map { $0.dim(3) }.max()!
        var padded: [MLXArray] = []
        for pv in images {
            let h = pv.dim(2), w = pv.dim(3)
            if h == maxH && w == maxW {
                padded.append(pv)
            } else {
                let result = MLXArray.zeros([1, 3, maxH, maxW], dtype: pv.dtype)
                result[0..., 0..., 0 ..< h, 0 ..< w] = pv
                padded.append(result)
            }
        }
        return concatenated(padded, axis: 0)
    }
}
