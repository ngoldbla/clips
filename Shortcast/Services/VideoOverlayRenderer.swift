import AVFoundation
import AppKit
import QuartzCore

/// Burns a short text "hook" into the top of a clip for its first seconds, then
/// fades it out — the classic short-form overlay. Re-encodes via an
/// `AVVideoCompositionCoreAnimationTool`, so it's only run at publish time on
/// clips whose overlay is enabled.
enum VideoOverlayRenderer {

    /// Renders `clipURL` with `text` shown for `holdSeconds` (then a short fade).
    /// Returns a new temp `.mp4`. Throws `MediaExtractorError.clipExportFailed`.
    static func render(clipURL: URL, text: String, holdSeconds: Double = 3) async throws -> URL {
        let asset = AVURLAsset(url: clipURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaExtractorError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)

        // Build a composition with the video (+ audio if present).
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaExtractorError.clipExportFailed("no video track") }
        let full = CMTimeRange(start: .zero, duration: duration)
        try compVideo.insertTimeRange(full, of: videoTrack, at: .zero)

        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudio.insertTimeRange(full, of: audioTrack, at: .zero)
        }

        // Oriented render size.
        let oriented = naturalSize.applying(transform)
        let renderSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = full
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // Core Animation layer tree: video + the hook band on top.
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        let band = makeHookBand(text: text, renderSize: renderSize)
        addOpacityAnimation(to: band,
                            total: CMTimeGetSeconds(duration),
                            hold: holdSeconds)
        parentLayer.addSublayer(band)

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer)

        guard let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw MediaExtractorError.clipExportFailed("export session unavailable") }
        export.videoComposition = videoComposition

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-clip-hook-\(UUID().uuidString).mp4")
        do {
            try await export.export(to: outputURL, as: .mp4)
        } catch {
            throw MediaExtractorError.clipExportFailed(error.localizedDescription)
        }
        return outputURL
    }

    // MARK: - Layers

    /// A rounded pill near the top holding the wrapped, centered hook text.
    /// (Core Animation's video coordinate space has its origin at the bottom-left,
    /// so "top" is a high y.)
    private static func makeHookBand(text: String, renderSize: CGSize) -> CALayer {
        let w = renderSize.width
        let fontSize = max(24, w * 0.058)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        let padding = fontSize * 0.55
        let bandWidth = w * 0.88
        let innerWidth = bandWidth - padding * 2

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textBounds = attributed.boundingRect(
            with: CGSize(width: innerWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textHeight = ceil(textBounds.height)
        let bandHeight = textHeight + padding * 2

        let topMargin = renderSize.height * 0.085
        let bandY = renderSize.height - topMargin - bandHeight

        let band = CALayer()
        band.frame = CGRect(x: (w - bandWidth) / 2, y: bandY, width: bandWidth, height: bandHeight)
        band.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        band.cornerRadius = bandHeight * 0.28
        band.masksToBounds = true

        let textLayer = CATextLayer()
        textLayer.string = attributed
        textLayer.isWrapped = true
        textLayer.alignmentMode = .center
        textLayer.contentsScale = 2
        textLayer.frame = CGRect(x: padding, y: padding, width: innerWidth, height: textHeight)
        band.addSublayer(textLayer)
        return band
    }

    /// Visible from 0→hold, fades over 0.5s, then stays hidden.
    private static func addOpacityAnimation(to layer: CALayer, total: Double, hold: Double) {
        let fade = 0.5
        let clampedHold = min(hold, max(0, total - fade))
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [1, 1, 0, 0]
        anim.keyTimes = [
            0,
            NSNumber(value: clampedHold / total),
            NSNumber(value: (clampedHold + fade) / total),
            1,
        ]
        anim.duration = total
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        layer.add(anim, forKey: "hookOpacity")
        layer.opacity = 0   // final state after the animation
    }
}
