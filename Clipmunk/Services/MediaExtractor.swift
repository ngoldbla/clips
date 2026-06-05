import AVFoundation
import Foundation

enum MediaExtractorError: LocalizedError {
    case noVideoTrack
    case audioExportFailed(String)
    case clipExportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "That file doesn't contain a video track."
        case .audioExportFailed(let detail):
            return "Couldn't extract the audio track: \(detail)"
        case .clipExportFailed(let detail):
            return "Couldn't cut the clip: \(detail)"
        }
    }
}

/// Validates dropped videos and pulls the audio track into a temp file.
///
/// Frame sampling for the model is handled inside `Gemma4Engine` (it has its
/// own `Gemma4VideoProcessor`). The one thing the model can't do itself is read
/// audio out of a video container, so that is this type's job.
enum MediaExtractor {

    /// Builds a `VideoJob` from a dropped file URL, verifying it really is a video.
    static func makeJob(from url: URL) async throws -> VideoJob {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw MediaExtractorError.noVideoTrack }
        let duration = try await asset.load(.duration)
        return VideoJob(url: url, durationSeconds: CMTimeGetSeconds(duration))
    }

    /// Extracts the audio track to a temporary `.m4a`. `maxSeconds` caps the
    /// export (default 35s, a little past Gemma's 30s audio window); pass `nil`
    /// to export the full track (used for transcribing a long video). Returns
    /// `nil` if the video has no audio track.
    static func extractAudio(from url: URL, maxSeconds: Double? = 35) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return nil }

        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else {
            throw MediaExtractorError.audioExportFailed("export session unavailable")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipmunk-audio-\(UUID().uuidString).m4a")

        if let maxSeconds {
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            let cap = CMTime(seconds: min(duration, maxSeconds), preferredTimescale: 600)
            export.timeRange = CMTimeRange(start: .zero, duration: cap)
        }

        do {
            try await export.export(to: outputURL, as: .m4a)
        } catch {
            throw MediaExtractorError.audioExportFailed(error.localizedDescription)
        }
        return outputURL
    }

    /// Cuts `[start, start+duration]` out of a video into a temporary `.mp4`.
    /// Tries a passthrough export first (no re-encode → near-instant, original
    /// quality); falls back to a re-encode if the source codec/container can't
    /// passthrough. Keeps the original aspect ratio (9:16 reframing is a future
    /// enhancement). `.mp4` matches the content type Upload-Post expects.
    static func cutClip(from url: URL, start: Double, duration: Double) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw MediaExtractorError.noVideoTrack }

        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600))

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipmunk-clip-\(UUID().uuidString).mp4")

        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
                continue
            }
            export.timeRange = range
            do {
                try await export.export(to: outputURL, as: .mp4)
                return outputURL
            } catch {
                // Passthrough can reject some codecs/ranges; try the re-encode.
                try? FileManager.default.removeItem(at: outputURL)
                if preset == AVAssetExportPresetHighestQuality {
                    throw MediaExtractorError.clipExportFailed(error.localizedDescription)
                }
            }
        }
        throw MediaExtractorError.clipExportFailed("no usable export preset")
    }
}
