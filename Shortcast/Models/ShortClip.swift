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

    // Per-clip publish state.
    private(set) var isPublishing = false
    private(set) var publishReport: UploadPostClient.PublishReport?
    var publishError: String?
    /// Set when the clip was published as a scheduled post (future date).
    private(set) var scheduledDate: Date?

    init(candidate: ClipCandidate, transcriptSlice: String,
         overlayEnabled: Bool, reframeEnabled: Bool) {
        self.candidate = candidate
        self.transcriptSlice = transcriptSlice
        // Prefer the model's short overlay hook; fall back to the caption hook.
        let raw = candidate.overlay.isEmpty ? candidate.hook : candidate.overlay
        self.overlayText = String(raw.prefix(60))
        self.overlayEnabled = overlayEnabled
        self.reframeEnabled = reframeEnabled
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
        return wantReframe || wantOverlay
    }

    /// Builds the file to upload or download: applies the vertical reframe and/or
    /// the burned-in text hook when enabled, otherwise returns the raw cut clip.
    /// `isTemporary` says whether the caller must delete the returned file.
    private func makeRenderedFile() async throws -> (url: URL, isTemporary: Bool) {
        guard let clipJob else { throw MomentFinderError.notReady }
        let hook = overlayText.trimmed
        let wantReframe = reframeEnabled && isLandscape
        let wantOverlay = overlayEnabled && !hook.isEmpty
        if wantReframe || wantOverlay,
           let url = try await VerticalReframer.process(
                clipURL: clipJob.url,
                reframe: wantReframe,
                overlayText: wantOverlay ? hook : nil) {
            return (url, true)
        }
        return (clipJob.url, false)
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
