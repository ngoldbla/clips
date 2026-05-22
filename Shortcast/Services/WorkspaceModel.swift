import Foundation
import Observation

/// Drives the main window's state machine: the dropped video, the model's
/// proposed variants (editable), and the publish flow.
@MainActor
@Observable
final class WorkspaceModel {

    enum Phase: Equatable {
        case empty
        case processing
        case results
    }

    private(set) var phase: Phase = .empty
    private(set) var job: VideoJob?

    /// The three proposed posts. Bound directly by the result cards for editing.
    var variants: [PostVariant] = []
    private(set) var detectedLanguage: String?

    /// Non-fatal banner shown on the drop screen (bad file, model still loading…).
    var errorMessage: String?

    // Publishing
    private(set) var isPublishing = false
    private(set) var publishReport: UploadPostClient.PublishReport?
    private(set) var publishError: String?

    // MARK: - Generation

    /// Validates a dropped file and runs the on-device generation.
    func process(url: URL, modelManager: ModelManager, settings: AppSettings) async {
        errorMessage = nil
        publishReport = nil
        publishError = nil

        guard let engine = modelManager.engine else {
            errorMessage = "The model is still getting ready — give it a moment, then drop the video again."
            return
        }

        let newJob: VideoJob
        do {
            newJob = try await MediaExtractor.makeJob(from: url)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        job = newJob
        variants = []
        detectedLanguage = nil
        phase = .processing

        do {
            let result = try await GemmaService.generate(
                job: newJob,
                engine: engine,
                languageOverride: settings.languageOverride,
                styleExamples: settings.styleExamples)
            variants = result.variants
            detectedLanguage = result.detectedLanguage
            phase = .results
        } catch {
            errorMessage = "Couldn't generate posts for that video. \(error.localizedDescription)"
            job = nil
            phase = .empty
        }
    }

    /// Returns to the empty drop state.
    func startOver() {
        job = nil
        variants = []
        detectedLanguage = nil
        publishReport = nil
        publishError = nil
        errorMessage = nil
        phase = .empty
    }

    // MARK: - Publishing

    func publish(settings: AppSettings) async {
        guard let job, !isPublishing else { return }
        publishError = nil
        publishReport = nil
        isPublishing = true
        defer { isPublishing = false }

        let client = UploadPostClient(
            apiKey: settings.apiKey,
            profileName: settings.profileName)
        do {
            publishReport = try await client.publish(
                videoURL: job.url,
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
