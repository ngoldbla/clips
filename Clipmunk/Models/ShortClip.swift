import Foundation
import Observation

/// One short being produced from a long video: the moment the Director picked,
/// the cut clip, its editable captions, and its own publish state. One
/// observable instance per card so each updates and publishes independently.
@MainActor
@Observable
final class ShortClip: Identifiable {

    let id = UUID()
    let candidate: ClipCandidate
    /// What's actually said in this clip's range — grounds the captioning.
    let transcriptSlice: String

    /// Animated word-level captions for this clip, built ONCE here from the
    /// clip's word stamps so the live preview and the exported/published file
    /// render from the exact same script (they can never drift).
    let captionScript: CaptionScript

    /// The cut clip (url + duration); nil until cutting finishes.
    var clipJob: VideoJob?
    /// The three platform posts, edited in place by the card.
    var variants: [PostVariant] = []
    var detectedLanguage: String?

    enum Stage: Equatable {
        case pending, cutting, captioning, ready
        case failed(String)
    }
    var stage: Stage = .pending

    /// Whether this clip is included in "Publish all approved".
    var isApproved = true

    /// Editable on-screen hook text, burned into the first seconds of the clip
    /// at publish time when `overlayEnabled` is on.
    var overlayText: String
    /// Per-clip switch for the burned-in text hook.
    var overlayEnabled: Bool

    /// Per-clip switch for reframing a horizontal clip to vertical 9:16 at
    /// publish time. Only takes effect when the cut clip is `isLandscape`.
    var reframeEnabled: Bool
    /// Whether the cut clip is wider than tall. Set by the pipeline after cutting;
    /// gates both the reframe and the per-clip toggle's visibility.
    var isLandscape = false

    /// Per-clip switch for burning animated word-level captions.
    var captionsEnabled: Bool
    /// Per-clip caption look.
    var captionStyle: CaptionStyle

    /// Per-clip switch for replacing the audio with a synthesized voiceover.
    var narrationEnabled: Bool
    /// Which Kokoro voice to narrate with (id like "af_heart").
    var narrationVoiceID: String

    // Per-clip publish state.
    private(set) var isPublishing = false
    private(set) var publishReport: UploadPostClient.PublishReport?
    var publishError: String?
    /// Set when the clip was published as a scheduled post (future date).
    private(set) var scheduledDate: Date?

    init(candidate: ClipCandidate, transcriptSlice: String,
         wordStamps: [WordStamp] = [],
         overlayEnabled: Bool, reframeEnabled: Bool,
         captionsEnabled: Bool = true, captionStyle: CaptionStyle = .default,
         narrationEnabled: Bool = false, narrationVoiceID: String = VoiceCatalog.defaultVoiceID) {
        self.candidate = candidate
        self.transcriptSlice = transcriptSlice
        // Build the caption script once, in source→clip-relative time, from the
        // words spoken in this clip's range.
        self.captionScript = CaptionScript.build(
            words: wordStamps, clipStart: candidate.start, clipEnd: candidate.end)
        // Prefer the model's short overlay hook; fall back to the caption hook.
        let raw = candidate.overlay.isEmpty ? candidate.hook : candidate.overlay
        self.overlayText = String(raw.prefix(60))
        self.overlayEnabled = overlayEnabled
        self.reframeEnabled = reframeEnabled
        self.captionsEnabled = captionsEnabled
        self.captionStyle = captionStyle
        self.narrationEnabled = narrationEnabled
        self.narrationVoiceID = narrationVoiceID
    }

    /// Rebuilds a clip from a persisted library entry, pointing at the copied cut
    /// video. The caption script and toggles come straight from the manifest, so
    /// a reopened job renders identically to when it was made.
    init(restoring stored: StoredClip, clipURL: URL) {
        self.candidate = stored.candidate
        self.transcriptSlice = stored.transcriptSlice
        self.captionScript = stored.captionScript
        self.overlayText = stored.overlayText
        self.overlayEnabled = stored.overlayEnabled
        self.reframeEnabled = stored.reframeEnabled
        self.captionsEnabled = stored.captionsEnabled
        self.captionStyle = CaptionStyle.preset(id: stored.captionStyleID)
        self.narrationEnabled = stored.narrationEnabled
        self.narrationVoiceID = stored.narrationVoiceID
        self.isLandscape = stored.isLandscape
        self.variants = stored.variants
        self.detectedLanguage = stored.detectedLanguage
        self.clipJob = VideoJob(url: clipURL, durationSeconds: stored.durationSeconds)
        self.stage = .ready
    }

    // ── DECISION (§7 source text): what the synthesized voice reads. ───────────
    // Faceless narration replaces the talking-head audio, so it should read the
    // Director's *script*, not echo the original speech. Default: the primary
    // platform caption body (PostVariant.summary), then the candidate hook, then
    // the transcript slice as a last resort. Kept short to stay near clip length.
    var narrationText: String {
        if let body = variants.first(where: { !$0.summary.trimmed.isEmpty })?.summary { return body }
        if !candidate.hook.trimmed.isEmpty { return candidate.hook }
        return transcriptSlice
    }

    /// A persistable snapshot of this clip for the job library. `clipFile` keys
    /// the copied cut video inside the job bundle.
    func stored() -> StoredClip {
        StoredClip(
            candidate: candidate, transcriptSlice: transcriptSlice,
            captionScript: captionScript, variants: variants,
            detectedLanguage: detectedLanguage, overlayText: overlayText,
            overlayEnabled: overlayEnabled, reframeEnabled: reframeEnabled,
            isLandscape: isLandscape, captionsEnabled: captionsEnabled,
            captionStyleID: captionStyle.id,
            narrationEnabled: narrationEnabled, narrationVoiceID: narrationVoiceID,
            clipFile: "\(id.uuidString).mp4",
            durationSeconds: clipJob?.durationSeconds ?? candidate.duration)
    }

    var isReadyToPublish: Bool {
        if case .ready = stage { return !variants.isEmpty }
        return false
    }

    /// Whether this clip will be rendered (reframed and/or overlaid) before it's
    /// uploaded or downloaded — i.e. the published file differs from the raw cut.
    var isRendered: Bool {
        let wantReframe = reframeEnabled && isLandscape
        let wantOverlay = overlayEnabled && !overlayText.trimmed.isEmpty
        let wantCaptions = captionsEnabled && !captionScript.isEmpty
        return wantReframe || wantOverlay || wantCaptions || narrationEnabled
    }

    /// Builds the file to upload or download: applies the vertical reframe and/or
    /// the burned-in text hook when enabled, otherwise returns the raw cut clip.
    /// `isTemporary` says whether the caller must delete the returned file.
    private func makeRenderedFile() async throws -> (url: URL, isTemporary: Bool) {
        guard let clipJob else { throw MomentFinderError.notReady }
        let hook = overlayText.trimmed
        let wantReframe = reframeEnabled && isLandscape
        let wantOverlay = overlayEnabled && !hook.isEmpty
        let wantCaptions = captionsEnabled && !captionScript.isEmpty

        // Narration pre-stage: synthesize the script, swap it onto the clip, and
        // re-sync captions proportionally over the narration length. Any failure
        // falls through to today's path (original audio + transcript-timed captions).
        var sourceURL = clipJob.url
        var narratedTemp: URL?
        // The narrated temp is owned here until it's either consumed by the
        // reframe pass or returned as the final file. Delete it on every other
        // exit — including a throw from VerticalReframer — so it's never orphaned.
        var keepNarratedTemp = false
        defer {
            if let narratedTemp, !keepNarratedTemp { try? FileManager.default.removeItem(at: narratedTemp) }
        }
        var renderCaptions: CaptionScript? = wantCaptions ? captionScript : nil
        if narrationEnabled, !narrationText.trimmed.isEmpty {
            do {
                let samples = try await NarrationService.shared.synthesize(
                    text: narrationText, voiceID: narrationVoiceID)
                let narrated = try await NarrationComposer.narratedClip(
                    clipURL: clipJob.url, samples: samples, sampleRate: NarrationService.sampleRate)
                sourceURL = narrated.url
                narratedTemp = narrated.url
                if wantCaptions {
                    let words = Transcript.synthesizeWords(
                        text: narrationText, start: 0, end: narrated.narrationLen)
                    renderCaptions = CaptionScript.build(words: words, clipStart: 0, clipEnd: narrated.narrationLen)
                }
            } catch {
                ShortClip.log("narration failed (\(error)) — rendering with original audio")
            }
        }

        // Existing render pipeline runs on `sourceURL` (narrated clip when on).
        // A throw here is covered by the defer above (narratedTemp is cleaned up).
        if wantReframe || wantOverlay || (renderCaptions?.isEmpty == false),
           let url = try await VerticalReframer.process(
                clipURL: sourceURL,
                reframe: wantReframe,
                overlayText: wantOverlay ? hook : nil,
                captionScript: (renderCaptions?.isEmpty == false) ? renderCaptions : nil,
                captionStyle: captionStyle) {
            return (url, true)   // narratedTemp consumed into `url`; defer deletes it
        }

        // Nothing to burn. If we narrated, the narrated clip IS the output.
        if let narratedTemp {
            keepNarratedTemp = true
            return (narratedTemp, true)
        }
        return (clipJob.url, false)
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[clipmunk/narration] \(message)\n".utf8))
    }

    // MARK: - Publishing

    func publish(settings: AppSettings, scheduledDate: Date? = nil) async {
        guard clipJob != nil, !isPublishing else { return }
        publishError = nil
        publishReport = nil
        isPublishing = true
        defer { isPublishing = false }

        // Reframe to vertical and/or burn the text hook now, if enabled. Upload
        // the rendered file and clean it up; the clean clip stays for previewing.
        let uploadURL: URL
        let isTemporary: Bool
        do {
            (uploadURL, isTemporary) = try await makeRenderedFile()
        } catch {
            publishError = "Couldn't prepare the clip for publishing: \(error.localizedDescription)"
            return
        }
        defer { if isTemporary { try? FileManager.default.removeItem(at: uploadURL) } }

        let client = UploadPostClient(
            apiKey: settings.apiKey,
            profileName: settings.profileName)
        do {
            publishReport = try await client.publish(
                videoURL: uploadURL,
                variants: variants,
                tiktokAsDraft: settings.tiktokAsDraft,
                scheduledDate: scheduledDate)
            self.scheduledDate = scheduledDate
        } catch {
            publishError = error.localizedDescription
        }
    }

    // MARK: - Download

    private(set) var isExporting = false
    var exportError: String?

    /// Renders the publish-ready file (reframe + overlay) and copies it to
    /// `destination`. Used by the "Download" action on each clip.
    func export(to destination: URL) async {
        guard clipJob != nil, !isExporting else { return }
        exportError = nil
        isExporting = true
        defer { isExporting = false }

        do {
            let (url, isTemporary) = try await makeRenderedFile()
            defer { if isTemporary { try? FileManager.default.removeItem(at: url) } }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Suggested filename for a download, derived from the hook.
    var suggestedFileName: String {
        let base = (candidate.hook.isEmpty ? "short" : candidate.hook)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (base.isEmpty ? "short" : String(base.prefix(40))) + ".mp4"
    }

    func dismissPublishResult() {
        publishReport = nil
        publishError = nil
    }
}
