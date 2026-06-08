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
            let lastFrameStart = CMTime(seconds: max(0, videoDur), preferredTimescale: 600) - frame
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
