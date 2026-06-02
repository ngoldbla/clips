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

    // Per-clip publish state.
    private(set) var isPublishing = false
    private(set) var publishReport: UploadPostClient.PublishReport?
    var publishError: String?

    init(candidate: ClipCandidate, transcriptSlice: String, overlayEnabled: Bool) {
        self.candidate = candidate
        self.transcriptSlice = transcriptSlice
        // Prefer the model's short overlay hook; fall back to the caption hook.
        let raw = candidate.overlay.isEmpty ? candidate.hook : candidate.overlay
        self.overlayText = String(raw.prefix(60))
        self.overlayEnabled = overlayEnabled
    }

    var isReadyToPublish: Bool {
        if case .ready = stage { return !variants.isEmpty }
        return false
    }

    // MARK: - Publishing

    func publish(settings: AppSettings) async {
        guard let clipJob, !isPublishing else { return }
        publishError = nil
        publishReport = nil
        isPublishing = true
        defer { isPublishing = false }

        // Burn the text hook into the clip now, if enabled. Upload the rendered
        // file and clean it up afterwards; the clean clip stays for previewing.
        var uploadURL = clipJob.url
        var rendered: URL?
        let hook = overlayText.trimmed
        if overlayEnabled && !hook.isEmpty {
            do {
                let url = try await VideoOverlayRenderer.render(clipURL: clipJob.url, text: hook)
                rendered = url
                uploadURL = url
            } catch {
                publishError = "Couldn't add the hook overlay: \(error.localizedDescription)"
                return
            }
        }
        defer { if let rendered { try? FileManager.default.removeItem(at: rendered) } }

        let client = UploadPostClient(
            apiKey: settings.apiKey,
            profileName: settings.profileName)
        do {
            publishReport = try await client.publish(
                videoURL: uploadURL,
                variants: variants,
                tiktokAsDraft: settings.tiktokAsDraft)
        } catch {
            publishError = error.localizedDescription
        }
    }

    func dismissPublishResult() {
        publishReport = nil
        publishError = nil
    }
}
