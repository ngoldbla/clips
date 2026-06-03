import Foundation
import Observation

/// Drives the main window's state machine. Two flows share it:
///  - short video → one set of editable variants → publish (the original path).
///  - long video → transcribe → find moments → cut + caption N shorts → publish.
@MainActor
@Observable
final class WorkspaceModel {

    /// What the user wants to do with a dropped video. Chosen explicitly on the
    /// drop screen rather than guessed from the video's length.
    enum InputMode: String, CaseIterable, Identifiable, Sendable {
        case shorts    // long video → cut into clips → caption each → publish
        case caption   // short video → captions → publish (the original flow)

        var id: String { rawValue }

        var title: String {
            switch self {
            case .caption: "Caption a short"
            case .shorts:  "Make shorts from a long video"
            }
        }

        var dropTitle: String {
            switch self {
            case .caption: "Drop a short video here"
            case .shorts:  "Drop a long video here"
            }
        }

        var dropSubtitle: String {
            switch self {
            case .caption: "Up to 60 seconds — a TikTok, Reel or Short"
            case .shorts:  "A podcast, talk or stream — we'll find the best moments and cut them"
            }
        }

        var symbol: String {
            switch self {
            case .caption: "film.stack"
            case .shorts:  "scissors"
            }
        }
    }

    /// The selected mode. Drives routing in `process(url:)`. Defaults to making
    /// shorts from a long video — the app's headline flow.
    var inputMode: InputMode = .shorts

    enum Phase: Equatable {
        case empty
        // Single-video flow:
        case processing
        case results
        // Shorts flow:
        case transcribing
        case findingMoments
        case shortsResults
    }

    private(set) var phase: Phase = .empty
    private(set) var job: VideoJob?

    /// The three proposed posts (single-video flow). Bound by the result cards.
    var variants: [PostVariant] = []
    private(set) var detectedLanguage: String?

    /// The generated shorts (long-video flow).
    var clips: [ShortClip] = []

    /// Owns transcription (sidecar `.srt`/`.vtt` or on-device WhisperKit).
    let transcription = TranscriptionService()

    /// Non-fatal banner shown on the drop screen.
    var errorMessage: String?
    /// Fatal pipeline error (transcription / moment-finding failed).
    private(set) var pipelineError: String?

    private var pipelineTask: Task<Void, Never>?

    // Publishing (single-video flow)
    private(set) var isPublishing = false
    private(set) var publishReport: UploadPostClient.PublishReport?
    private(set) var publishError: String?
    /// True while "Publish all approved" runs over the shorts.
    private(set) var isPublishingAll = false

    var isBusy: Bool {
        switch phase {
        case .processing, .transcribing, .findingMoments: return true
        default: return false
        }
    }

    // MARK: - Entry

    /// Validates a dropped file and routes to the right flow based on length.
    func process(url: URL, modelManager: ModelManager, settings: AppSettings) async {
        errorMessage = nil
        publishReport = nil
        publishError = nil
        pipelineError = nil

        let newJob: VideoJob
        do {
            newJob = try await MediaExtractor.makeJob(from: url)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        switch inputMode {
        case .caption:
            await processSingleVideo(job: newJob, modelManager: modelManager, settings: settings)
        case .shorts:
            startShortsPipeline(job: newJob, modelManager: modelManager, settings: settings)
        }
    }

    // MARK: - Single-video flow (unchanged behaviour)

    private func processSingleVideo(job newJob: VideoJob, modelManager: ModelManager, settings: AppSettings) async {
        guard let engine = modelManager.engine else {
            errorMessage = "The model is still getting ready — give it a moment, then drop the video again."
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

    // MARK: - Shorts flow

    private func startShortsPipeline(job newJob: VideoJob, modelManager: ModelManager, settings: AppSettings) {
        cleanupClipTempFiles()
        job = newJob
        clips = []
        variants = []
        pipelineError = nil
        phase = .transcribing

        pipelineTask = Task {
            await self.runShortsPipeline(job: newJob, modelManager: modelManager, settings: settings)
        }
    }

    private func runShortsPipeline(job: VideoJob, modelManager: ModelManager, settings: AppSettings) async {
        let pipelineStart = Date()
        Self.log("pipeline start — copywriter=\(settings.copywriterModel.rawValue)")
        do {
            // 1. Transcript: sidecar .srt/.vtt if present, else WhisperKit.
            phase = .transcribing
            let t0 = Date()
            let transcript = try await transcription.transcript(
                for: job.url, languageHint: settings.languageOverride)
            // Trust the language of the actual text over Whisper's 30s auto-detect.
            let captionLanguage = transcript.contentLanguage ?? transcript.language
            Self.log("transcript ready in \(Self.elapsed(since: t0)) — whisper=\(transcript.language ?? "?"), text=\(captionLanguage ?? "?")")
            try Task.checkCancellation()

            // 2. Find the viral moments — one Qwen pass over the full transcript.
            phase = .findingMoments
            let t1 = Date()
            await modelManager.prepareDirector(profile: settings.copywriterModel.directorProfile)
            Self.log("director ready in \(Self.elapsed(since: t1)) — \(settings.copywriterModel.directorProfile.displayName)")
            // The two text models write the captions in this same pass.
            let useInlineCaptions = settings.copywriterModel.usesInlineCaptions
            let t2 = Date()
            let candidates = try await modelManager.momentFinder.findMoments(
                transcript: transcript.srtLike(),
                includeCaptions: useInlineCaptions,
                language: captionLanguage,
                styleExamples: settings.styleExamples)
            Self.log("found \(candidates.count) moment(s) in \(Self.elapsed(since: t2)), captions inline=\(useInlineCaptions)")
            try Task.checkCancellation()

            // Seed cards; they fill in as each clip is cut + captioned.
            clips = candidates.map {
                ShortClip(candidate: $0,
                          transcriptSlice: transcript.slice(start: $0.start, end: $0.end),
                          overlayEnabled: settings.burnHookOverlay,
                          reframeEnabled: settings.reframeToVertical)
            }
            phase = .shortsResults

            // On tight RAM, free the Director before the Gemma E4B clip-watcher.
            if settings.copywriterModel.watchesClips {
                modelManager.freeDirectorIfMemoryTight()
            }

            // 3+4. Cut, then caption, each clip in turn (one MLX engine → serial).
            for (index, clip) in clips.enumerated() {
                try Task.checkCancellation()
                do {
                    clip.stage = .cutting
                    let tCut = Date()
                    let clipURL = try await MediaExtractor.cutClip(
                        from: job.url,
                        start: clip.candidate.start,
                        duration: clip.candidate.duration)
                    clip.clipJob = VideoJob(url: clipURL, durationSeconds: clip.candidate.duration)
                    // Only horizontal clips get the vertical-reframe option.
                    clip.isLandscape = await VerticalReframer.isLandscape(url: clipURL)

                    if !clip.candidate.variants.isEmpty {
                        // Captions already came from the Director's one pass.
                        clip.variants = clip.candidate.variants
                        clip.detectedLanguage = captionLanguage
                        clip.stage = .ready
                        Self.log("clip \(index + 1)/\(clips.count) ready — cut \(Self.elapsed(since: tCut)), captions inline")
                    } else {
                        clip.stage = .captioning
                        let tCap = Date()
                        let result = try await captionClip(
                            clip, modelManager: modelManager, settings: settings,
                            transcriptLanguage: captionLanguage)
                        clip.variants = result.variants
                        clip.detectedLanguage = result.detectedLanguage
                        clip.stage = .ready
                        Self.log("clip \(index + 1)/\(clips.count) ready — cut \(Self.elapsed(since: tCut, to: tCap)), caption \(Self.elapsed(since: tCap))")
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    clip.stage = .failed(error.localizedDescription)
                    Self.log("clip \(index + 1)/\(clips.count) failed: \(error.localizedDescription)")
                }
            }
            Self.log("pipeline done — \(clips.count) clip(s) in \(Self.elapsed(since: pipelineStart)) total")
        } catch is CancellationError {
            cleanupClipTempFiles()
            clips = []
            self.job = nil
            phase = .empty
        } catch {
            pipelineError = error.localizedDescription
            errorMessage = "Couldn't make shorts from that video. \(error.localizedDescription)"
            self.job = nil
            clips = []
            phase = .empty
        }
    }

    private func captionClip(_ clip: ShortClip, modelManager: ModelManager, settings: AppSettings,
                             transcriptLanguage: String?) async throws -> GenerationResult {
        // Lock the output language to what Whisper detected unless the user set a
        // manual override — small captioners otherwise drift (e.g. Spanish → pt-BR).
        let effectiveLanguage = settings.languageOverride.trimmed.isEmpty
            ? (transcriptLanguage ?? "")
            : settings.languageOverride

        switch settings.copywriterModel {
        case .gemmaE4B:
            guard let engine = modelManager.engine, let clipJob = clip.clipJob else {
                throw MomentFinderError.notReady
            }
            return try await GemmaService.generate(
                job: clipJob,
                engine: engine,
                languageOverride: effectiveLanguage,
                styleExamples: settings.styleExamples)
        case .gemma12B, .qwen35_9b:
            // Inline-caption models normally write captions in the moment-finding
            // pass; this is the fallback per-clip path using the same Director.
            await modelManager.prepareDirector(profile: settings.copywriterModel.directorProfile)
            return try await modelManager.momentFinder.caption(
                transcriptSlice: clip.transcriptSlice,
                hook: clip.candidate.hook,
                languageOverride: effectiveLanguage,
                styleExamples: settings.styleExamples)
        }
    }

    func cancelPipeline() {
        pipelineTask?.cancel()
    }

    // MARK: - Timing logs (stderr; visible when launched from the terminal)

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[shortcast/pipeline] \(message)\n".utf8))
    }

    /// Formatted seconds elapsed between two dates (defaults `to` = now).
    nonisolated static func elapsed(since start: Date, to end: Date = Date()) -> String {
        String(format: "%.1fs", end.timeIntervalSince(start))
    }

    // MARK: - Reset

    /// Returns to the empty drop state and cleans up temp files.
    func startOver() {
        pipelineTask?.cancel()
        cleanupClipTempFiles()
        job = nil
        variants = []
        clips = []
        detectedLanguage = nil
        publishReport = nil
        publishError = nil
        errorMessage = nil
        pipelineError = nil
        phase = .empty
    }

    private func cleanupClipTempFiles() {
        for clip in clips {
            if let url = clip.clipJob?.url {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Publishing (single-video flow)

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

    // MARK: - Publishing (shorts flow)

    var approvedReadyCount: Int {
        clips.filter { $0.isApproved && $0.isReadyToPublish }.count
    }

    /// Publishes every approved, ready clip in turn. Each clip keeps its own
    /// status, so a partial batch is reflected per card. Stops early if a clip
    /// hits the Upload-Post monthly limit.
    func publishAllApproved(settings: AppSettings) async {
        guard !isPublishingAll else { return }
        isPublishingAll = true
        defer { isPublishingAll = false }

        for clip in clips where clip.isApproved && clip.isReadyToPublish {
            await clip.publish(settings: settings)
            if let error = clip.publishError, error.localizedCaseInsensitiveContains("limit") {
                break
            }
        }
    }

    /// True while "Schedule all" runs.
    private(set) var isSchedulingAll = false

    /// The dates each approved, ready clip would be scheduled to: the first at
    /// `start`, then one every `intervalDays`. Used for the schedule preview.
    func schedulePlan(start: Date, intervalDays: Int) -> [(clip: ShortClip, date: Date)] {
        let cal = Calendar.current
        var date = start
        var plan: [(ShortClip, Date)] = []
        for clip in clips where clip.isApproved && clip.isReadyToPublish {
            plan.append((clip, date))
            date = cal.date(byAdding: .day, value: max(1, intervalDays), to: date) ?? date
        }
        return plan
    }

    /// Schedules every approved, ready clip: the first at `start`, then one every
    /// `intervalDays`. Sequential; stops cleanly on the monthly limit.
    func scheduleAllApproved(start: Date, intervalDays: Int, settings: AppSettings) async {
        guard !isSchedulingAll else { return }
        isSchedulingAll = true
        defer { isSchedulingAll = false }

        for (clip, date) in schedulePlan(start: start, intervalDays: intervalDays) {
            await clip.publish(settings: settings, scheduledDate: date)
            if let error = clip.publishError, error.localizedCaseInsensitiveContains("limit") {
                break
            }
        }
    }
}
