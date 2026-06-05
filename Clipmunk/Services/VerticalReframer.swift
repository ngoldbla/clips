import AVFoundation
import CoreImage
import Vision
import QuartzCore

/// Reframes a horizontal (16:9) clip into a vertical 9:16 short, the way
/// short-form editors do it: it follows the speaker with a smoothed "virtual
/// camera" (Apple Vision face detection → a panning crop window), and falls back
/// to a blurred-background letterbox when there's no clear single face.
///
/// Everything is on-device and native — no Python, MediaPipe, YOLO or FFmpeg.
/// The pan is expressed as `setTransformRamp` keyframes on a layer instruction,
/// so AVFoundation interpolates the motion on the GPU in a single export pass,
/// and the optional text hook is burned in the same pass (reusing
/// `VideoOverlayRenderer`'s band helpers).
@MainActor
enum VerticalReframer {

    /// 1080×1920 — the standard short-form canvas.
    private static let outW: CGFloat = 1080
    private static let outH: CGFloat = 1920

    // MARK: - Public

    /// True when the video is wider than it is tall (so reframing to 9:16 makes
    /// sense). Used by the pipeline to decide whether to offer the per-clip
    /// "Convert to vertical" toggle.
    static func isLandscape(url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return false }
        let oriented = size.applying(transform)
        return abs(oriented.width) > abs(oriented.height)
    }

    /// Produces the file to upload for a clip. Returns `nil` when there's nothing
    /// to do (no reframe and no overlay) — the caller then uploads the original.
    ///
    /// - `reframe`: convert 16:9 → 9:16 (caller already checked it's landscape).
    /// - `overlayText`: burn this text hook into the first seconds (nil = none).
    /// - `captionScript`: animated word-level captions to burn in (nil/empty = none).
    /// - `captionStyle`: how those captions look.
    static func process(
        clipURL: URL, reframe: Bool, overlayText: String?,
        captionScript: CaptionScript? = nil, captionStyle: CaptionStyle = .default
    ) async throws -> URL? {
        let hook = overlayText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantOverlay = !(hook?.isEmpty ?? true)
        let captions = (captionScript?.isEmpty == false) ? captionScript : nil
        let wantCaptions = captions != nil

        // No reframe → overlay/caption-only path.
        guard reframe else {
            if wantOverlay || wantCaptions {
                return try await VideoOverlayRenderer.render(
                    clipURL: clipURL, text: wantOverlay ? hook! : "",
                    captionScript: captions, captionStyle: captionStyle)
            }
            return nil
        }

        let asset = AVURLAsset(url: clipURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaExtractorError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let oriented = naturalSize.applying(transform)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))

        // Sample faces across the clip; if enough frames have a clear face, track
        // it. Otherwise fall back to a blurred-background letterbox.
        let totalSeconds = CMTimeGetSeconds(duration)
        let samples = await sampleFaces(clipURL: clipURL, duration: totalSeconds)
        let withFace = samples.filter { $0.midX != nil }.count
        let trackable = !samples.isEmpty && Double(withFace) / Double(samples.count) >= 0.4

        if trackable {
            let keyframes = panPath(from: samples, orientedSize: orientedSize)
            return try await renderTracking(
                asset: asset, videoTrack: videoTrack, duration: duration,
                transform: transform, keyframes: keyframes,
                overlayText: wantOverlay ? hook! : nil,
                captionScript: captions, captionStyle: captionStyle)
        } else {
            let reframed = try await renderBlurred(asset: asset)
            guard wantOverlay || wantCaptions else { return reframed }
            // B-roll fallback only: a second pass to add the hook and/or captions.
            let withOverlay = try await VideoOverlayRenderer.render(
                clipURL: reframed, text: wantOverlay ? hook! : "",
                captionScript: captions, captionStyle: captionStyle)
            try? FileManager.default.removeItem(at: reframed)
            return withOverlay
        }
    }

    // MARK: - Face sampling (Vision) + audio-aware active speaker

    private struct Sample { let time: Double; let midX: CGFloat? }
    private struct DetectedFace { let box: CGRect; let mouthOpen: CGFloat }

    nonisolated private static let sampleStep = 0.5

    /// Samples faces every ~0.5 s. With multiple people AND audio, it follows the
    /// ACTIVE speaker — the face whose mouth moves while there's speech — using
    /// IoU face-tracking and hysteresis so rapid back-and-forth doesn't jitter the
    /// camera. Single-face or no-audio clips fall back to the largest face, i.e.
    /// today's behaviour (regression-safe). `midX` is 0…1 of the oriented frame;
    /// nil when no face is found. Runs off the main actor and only takes the URL,
    /// so no non-Sendable AVFoundation object crosses isolation.
    nonisolated private static func sampleFaces(clipURL: URL, duration: Double) async -> [Sample] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clipURL))
        generator.appliesPreferredTrackTransform = true   // upright frames
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 512, height: 512)  // plenty for detection

        var times: [Double] = []
        var perFrame: [[DetectedFace]] = []
        var t = 0.0
        while t < max(sampleStep, duration) {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let (cgImage, _) = try? await generator.image(at: time) {
                perFrame.append(facesWithMouth(in: cgImage))
            } else {
                perFrame.append([])
            }
            times.append(t)
            t += sampleStep
        }

        // Single-/no-face clips: exactly today's "largest face" behaviour.
        let maxFaces = perFrame.map(\.count).max() ?? 0
        if maxFaces <= 1 {
            return zip(times, perFrame).map { time, faces in
                Sample(time: time, midX: faces.max { areaOf($0.box) < areaOf($1.box) }?.box.midX)
            }
        }

        let envelope = await AudioActivityAnalyzer.envelope(clipURL: clipURL, cadence: sampleStep)
        return activeSpeakerSamples(times: times, perFrame: perFrame, envelope: envelope)
    }

    nonisolated private static func areaOf(_ r: CGRect) -> CGFloat { r.width * r.height }

    /// All faces in a frame, each with a mouth-openness proxy (vertical lip span
    /// in face-relative space) from Vision landmarks — native, no MediaPipe.
    nonisolated private static func facesWithMouth(in cgImage: CGImage) -> [DetectedFace] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let faces = request.results else { return [] }
        return faces.map { DetectedFace(box: $0.boundingBox, mouthOpen: mouthOpenness($0)) }
    }

    /// Vertical extent of the outer lips in the face's own bounding-box space
    /// (≈ how open the mouth is); 0 when no lip landmarks are available.
    nonisolated private static func mouthOpenness(_ face: VNFaceObservation) -> CGFloat {
        guard let lips = face.landmarks?.outerLips, lips.pointCount > 0 else { return 0 }
        let ys = lips.normalizedPoints.map(\.y)
        guard let lo = ys.min(), let hi = ys.max() else { return 0 }
        return hi - lo
    }

    /// One face followed across frames.
    private struct Track { var box: CGRect; var mouth: CGFloat; var lastFrame: Int }

    /// Links faces across frames by bounding-box IoU, scores each as a speaker
    /// (size × centering × speech-weighted mouth movement), and picks the active
    /// speaker per frame with hysteresis. Returns the chosen face's `midX`.
    nonisolated private static func activeSpeakerSamples(
        times: [Double], perFrame: [[DetectedFace]], envelope: [AudioActivityAnalyzer.Activity]
    ) -> [Sample] {
        var tracks: [Int: Track] = [:]
        var nextID = 0
        var currentSpeaker: Int?
        var samples: [Sample] = []
        let switchMargin: CGFloat = 0.25      // a challenger must beat the incumbent by 25%
        let referenceMouth: CGFloat = 0.12    // a typical "open mouth" lip span

        for (i, faces) in perFrame.enumerated() {
            // 1. Link this frame's faces to recently-seen tracks by IoU.
            var present: [(id: Int, face: DetectedFace)] = []
            var used = Set<Int>()
            for face in faces {
                let candidate = tracks
                    .filter { !used.contains($0.key) && i - $0.value.lastFrame <= 4 }
                    .max { iou($0.value.box, face.box) < iou($1.value.box, face.box) }
                if let candidate, iou(candidate.value.box, face.box) > 0.3 {
                    used.insert(candidate.key)
                    tracks[candidate.key] = Track(
                        box: face.box,
                        mouth: candidate.value.mouth * 0.5 + face.mouthOpen * 0.5,
                        lastFrame: i)
                    present.append((candidate.key, face))
                } else {
                    let id = nextID; nextID += 1
                    tracks[id] = Track(box: face.box, mouth: face.mouthOpen, lastFrame: i)
                    present.append((id, face))
                }
            }
            guard !present.isEmpty else { samples.append(Sample(time: times[i], midX: nil)); continue }

            // 2. Score each present face as a speaker. A talking mouth during
            //    audio-active moments is the strongest signal.
            let speaking = CGFloat(AudioActivityAnalyzer.speaking(at: times[i], in: envelope))
            let scored = present.map { entry -> (id: Int, midX: CGFloat, s: CGFloat) in
                let area = areaOf(entry.face.box)
                let centering = 1 - abs(entry.face.box.midX - 0.5)            // 0.5…1
                let mouth = min(1.5, (tracks[entry.id]?.mouth ?? entry.face.mouthOpen) / referenceMouth)
                let speech = 1 + speaking * 1.5 * mouth
                return (entry.id, entry.face.box.midX, area * (0.6 + 0.4 * centering) * speech)
            }
            let best = scored.max { $0.s < $1.s }!

            // 3. Hysteresis: switch only when a challenger clearly wins AND someone
            //    is actually speaking — otherwise hold (no chasing during silence).
            if let inc = currentSpeaker.flatMap({ id in scored.first { $0.id == id } }) {
                let challengerWins = best.id != inc.id && best.s > inc.s * (1 + switchMargin) && speaking > 0.25
                currentSpeaker = challengerWins ? best.id : inc.id
            } else {
                currentSpeaker = best.id
            }
            let chosen = scored.first { $0.id == currentSpeaker } ?? best
            samples.append(Sample(time: times[i], midX: chosen.midX))
        }
        return samples
    }

    /// Intersection-over-union of two normalized boxes.
    nonisolated private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let interArea = inter.width * inter.height
        let union = areaOf(a) + areaOf(b) - interArea
        return union > 0 ? interArea / union : 0
    }

    // MARK: - Pan path (the "virtual camera")

    private struct Keyframe { let time: Double; let cropX: CGFloat }

    /// Turns face samples into a smoothed sequence of crop-window centres, in the
    /// scaled render space. "Heavy tripod": the camera only pans when the subject
    /// leaves a safe zone, and never faster than a capped speed — no jitter.
    private static func panPath(from samples: [Sample], orientedSize: CGSize) -> [Keyframe] {
        let scale = outH / orientedSize.height
        let scaledW = orientedSize.width * scale
        let cropMaxX = max(0, scaledW - outW)
        let center = cropMaxX / 2

        // Raw per-sample target, holding the last known position over gaps.
        var lastTarget = center
        let targets: [(time: Double, x: CGFloat)] = samples.map { s in
            if let midX = s.midX {
                lastTarget = min(max(midX * scaledW - outW / 2, 0), cropMaxX)
            }
            return (s.time, lastTarget)
        }
        guard !targets.isEmpty else { return [Keyframe(time: 0, cropX: center)] }

        let safeZone = outW * 0.18
        let maxSpeed = outW * 0.75          // render px per second
        var current = targets[0].x
        var keyframes = [Keyframe(time: targets[0].time, cropX: current)]

        for i in 1..<targets.count {
            let dt = targets[i].time - targets[i - 1].time
            let target = targets[i].x
            let diff = target - current
            if abs(diff) > safeZone {
                let step = min(abs(diff), maxSpeed * dt)
                current += (diff > 0 ? 1 : -1) * step
                current = min(max(current, 0), cropMaxX)
            }
            keyframes.append(Keyframe(time: targets[i].time, cropX: current))
        }
        return keyframes
    }

    /// Maps the oriented video into the 1080×1920 canvas with the crop window at
    /// `cropX`: orient → scale-to-height → translate horizontally.
    private static func transform(for cropX: CGFloat, base: CGAffineTransform,
                                  orientedSize: CGSize) -> CGAffineTransform {
        let scale = outH / orientedSize.height
        return base
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: -cropX, y: 0))
    }

    // MARK: - Tracking composition (transform ramps)

    /// Builds the 9:16 tracking composition (pan ramps, no overlay) — shared by
    /// the export path and the live preview.
    private static func buildTracking(
        asset: AVAsset, videoTrack: AVAssetTrack, duration: CMTime,
        transform base: CGAffineTransform, keyframes: [Keyframe]
    ) async throws -> (composition: AVMutableComposition, videoComposition: AVMutableVideoComposition) {
        let oriented = try await videoTrack.load(.naturalSize).applying(base)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))

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

        let renderSize = CGSize(width: outW, height: outH)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = full
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)

        // Pan as a chain of linear transform ramps between sampled keyframes.
        let frames = keyframes.isEmpty
            ? [Keyframe(time: 0, cropX: max(0, orientedSize.width * (outH / orientedSize.height) - outW) / 2)]
            : keyframes
        layerInstruction.setTransform(
            transform(for: frames[0].cropX, base: base, orientedSize: orientedSize), at: .zero)
        for i in 0..<frames.count - 1 where frames.count > 1 {
            let startT = CMTime(seconds: frames[i].time, preferredTimescale: 600)
            let endT = CMTime(seconds: frames[i + 1].time, preferredTimescale: 600)
            layerInstruction.setTransformRamp(
                fromStart: transform(for: frames[i].cropX, base: base, orientedSize: orientedSize),
                toEnd: transform(for: frames[i + 1].cropX, base: base, orientedSize: orientedSize),
                timeRange: CMTimeRange(start: startT, end: endT))
        }
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        return (composition, videoComposition)
    }

    /// Export path: tracking reframe + optional burned-in captions + hook, one pass.
    private static func renderTracking(
        asset: AVAsset, videoTrack: AVAssetTrack, duration: CMTime,
        transform base: CGAffineTransform, keyframes: [Keyframe],
        overlayText: String?,
        captionScript: CaptionScript? = nil, captionStyle: CaptionStyle = .default
    ) async throws -> URL {
        let (composition, videoComposition) = try await buildTracking(
            asset: asset, videoTrack: videoTrack, duration: duration,
            transform: base, keyframes: keyframes)

        let renderSize = videoComposition.renderSize
        let total = CMTimeGetSeconds(duration)
        let captionLayer = captionScript.flatMap {
            CaptionRenderer.layer(for: $0, renderSize: renderSize, style: captionStyle, total: total)
        }

        if overlayText != nil || captionLayer != nil {
            let parentLayer = CALayer()
            let videoLayer = CALayer()
            parentLayer.frame = CGRect(origin: .zero, size: renderSize)
            videoLayer.frame = parentLayer.frame
            parentLayer.addSublayer(videoLayer)

            // Captions sit under the hook band (the band is top-of-frame, captions
            // are low/centre — they don't overlap).
            if let captionLayer { parentLayer.addSublayer(captionLayer) }

            if let overlayText {
                let band = VideoOverlayRenderer.makeHookBand(text: overlayText, renderSize: renderSize)
                VideoOverlayRenderer.addOpacityAnimation(to: band, total: total, hold: 3)
                parentLayer.addSublayer(band)
            }

            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        }

        return try await export(composition, videoComposition: videoComposition)
    }

    // MARK: - Blurred-background fallback (Core Image)

    /// Builds the blurred-letterbox CI composition — shared by export and preview.
    private static func buildBlurred(asset: AVAsset) -> AVMutableVideoComposition {
        let canvas = CGRect(x: 0, y: 0, width: outW, height: outH)
        let videoComposition = AVMutableVideoComposition(asset: asset) { request in
            let src = request.sourceImage
            let s = src.extent
            guard s.width > 0, s.height > 0 else { request.finish(with: src, context: nil); return }
            // Normalize origin to (0,0).
            let normalized = src.transformed(
                by: CGAffineTransform(translationX: -s.minX, y: -s.minY))

            // Background: scale to fill, centre, blur, crop to canvas.
            let bgScale = max(outW / s.width, outH / s.height)
            let bg = normalized
                .transformed(by: CGAffineTransform(scaleX: bgScale, y: bgScale))
                .transformed(by: CGAffineTransform(
                    translationX: (outW - s.width * bgScale) / 2,
                    y: (outH - s.height * bgScale) / 2))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: 28)
                .cropped(to: canvas)

            // Foreground: scale to width, centre vertically.
            let fgScale = outW / s.width
            let fg = normalized
                .transformed(by: CGAffineTransform(scaleX: fgScale, y: fgScale))
                .transformed(by: CGAffineTransform(
                    translationX: 0, y: (outH - s.height * fgScale) / 2))

            let out = fg.composited(over: bg).cropped(to: canvas)
            request.finish(with: out, context: nil)
        }
        videoComposition.renderSize = canvas.size
        return videoComposition
    }

    private static func renderBlurred(asset: AVAsset) async throws -> URL {
        try await export(asset, videoComposition: buildBlurred(asset: asset))
    }

    // MARK: - Live preview (reframe applied via videoComposition, no export)

    /// An `AVPlayerItem` that plays the clip already reframed to 9:16 — so the
    /// in-app "Play with sound" preview matches the downloaded/published file.
    /// The burned-in text hook is export-only and is intentionally not shown
    /// here. Returns nil when the clip isn't being reframed (play the raw clip).
    @MainActor
    static func previewItem(clipURL: URL, reframe: Bool) async -> AVPlayerItem? {
        guard reframe else { return nil }
        let asset = AVURLAsset(url: clipURL)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration),
              let naturalSize = try? await videoTrack.load(.naturalSize),
              let transform = try? await videoTrack.load(.preferredTransform)
        else { return nil }

        let oriented = naturalSize.applying(transform)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))

        let samples = await sampleFaces(clipURL: clipURL, duration: CMTimeGetSeconds(duration))
        let withFace = samples.filter { $0.midX != nil }.count
        let trackable = !samples.isEmpty && Double(withFace) / Double(samples.count) >= 0.4

        if trackable {
            let keyframes = panPath(from: samples, orientedSize: orientedSize)
            guard let (composition, vc) = try? await buildTracking(
                asset: asset, videoTrack: videoTrack, duration: duration,
                transform: transform, keyframes: keyframes) else { return nil }
            let item = AVPlayerItem(asset: composition)
            item.videoComposition = vc
            return item
        } else {
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = buildBlurred(asset: asset)
            return item
        }
    }

    // MARK: - Export

    private static func export(_ asset: AVAsset,
                               videoComposition: AVVideoComposition) async throws -> URL {
        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else { throw MediaExtractorError.clipExportFailed("export session unavailable") }
        export.videoComposition = videoComposition

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipmunk-clip-vertical-\(UUID().uuidString).mp4")
        do {
            try await export.export(to: outputURL, as: .mp4)
        } catch {
            throw MediaExtractorError.clipExportFailed(error.localizedDescription)
        }
        return outputURL
    }
}
