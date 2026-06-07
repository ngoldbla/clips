import Foundation
import Observation
import UserNotifications

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

    /// The batch queue: every dropped video lands here and is drained serially.
    var queue: [QueuedJob] = []

    /// Finished jobs persisted on disk (the History view), newest first.
    private(set) var library: [StoredJob] = []

    /// Owns transcription (sidecar `.srt`/`.vtt` or on-device WhisperKit).
    let transcription = TranscriptionService()

    init() {
        library = JobLibrary.list()
    }

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

    /// Enqueues a single dropped video (kept for the existing single-drop call site).
    func process(url: URL, modelManager: ModelManager, settings: AppSettings) async {
        enqueue(urls: [url], modelManager: modelManager, settings: settings)
    }

    /// Enqueues every dropped video and starts draining if the queue was idle.
    func enqueue(urls: [URL], modelManager: ModelManager, settings: AppSettings) {
        guard !urls.isEmpty else { return }
        let mode = inputMode
        queue.append(contentsOf: urls.map { QueuedJob(url: $0, mode: mode) })
        startDrainingIfIdle(modelManager: modelManager, settings: settings)
    }

    /// Enqueues a YouTube link for the shorts flow. The drainer downloads the
    /// video (opt-in yt-dlp) and fetches its captions. Validates the link first.
    func enqueueYouTube(link: String, modelManager: ModelManager, settings: AppSettings) {
        guard let id = YouTubeIngest.videoID(from: link),
              let watch = URL(string: YouTubeIngest.watchURLString(id: id)) else {
            errorMessage = "That doesn't look like a YouTube link."
            return
        }
        queue.append(QueuedJob(url: watch, mode: .shorts, youTubeID: id))
        startDrainingIfIdle(modelManager: modelManager, settings: settings)
    }

    private func startDrainingIfIdle(modelManager: ModelManager, settings: AppSettings) {
        if pipelineTask == nil {
            pipelineTask = Task { await drainQueue(modelManager: modelManager, settings: settings) }
        }
    }

    /// Processes queued jobs one at a time (the MLX engine is single-instance, so
    /// serial is correct). Each finished shorts job is saved to the local library
    /// and a notification posted; a failure marks that job and moves on.
    private func drainQueue(modelManager: ModelManager, settings: AppSettings) async {
        defer { pipelineTask = nil }
        while let job = queue.first(where: { $0.status == .pending }) {
            if Task.isCancelled { return }
            job.status = .processing
            errorMessage = nil; publishReport = nil; publishError = nil; pipelineError = nil
            do {
                // YouTube job: download the video (opt-in yt-dlp) and try to fetch
                // its captions first, so we can skip Whisper when they exist.
                let videoURL: URL
                var prefetched: Transcript?
                if let id = job.youTubeID {
                    guard YtDlpManager.isAvailable else { throw WorkspaceError.ytDlpMissing }
                    phase = .transcribing
                    videoURL = try await YtDlpManager.downloadVideo(from: job.url.absoluteString)
                    prefetched = try? await YouTubeIngest.fetchTranscript(
                        videoID: id, languageHint: settings.languageOverride)
                } else {
                    videoURL = job.url
                }
                let removeSource = job.youTubeID != nil
                defer { if removeSource { try? FileManager.default.removeItem(at: videoURL) } }

                let videoJob = try await MediaExtractor.makeJob(from: videoURL)
                switch job.mode {
                case .caption:
                    try await processSingleVideo(job: videoJob, modelManager: modelManager, settings: settings)
                case .shorts:
                    try await runShortsPipeline(
                        job: videoJob, modelManager: modelManager, settings: settings,
                        prefetchedTranscript: prefetched)
                    persistFinishedShortsJob(source: videoJob)
                }
                job.status = .finished
                notify(title: "Shorts ready", body: "\(job.fileName) — \(clips.count) clip(s) ready.")
            } catch is CancellationError {
                job.status = .failed("Cancelled")
                return
            } catch {
                job.status = .failed(error.localizedDescription)
                notify(title: "Job failed", body: "\(job.fileName): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Single-video flow (unchanged behaviour)

    private func processSingleVideo(job newJob: VideoJob, modelManager: ModelManager, settings: AppSettings) async throws {
        job = newJob
        variants = []
        detectedLanguage = nil
        phase = .processing

        // "Caption a short" always uses the multimodal E4B engine. On 16 GB it
        // isn't preloaded at launch, so bring it up now (idempotent if already
        // resident); ProcessingView surfaces the download/load progress.
        await modelManager.prepareIfNeeded()
        guard let engine = modelManager.engine else {
            phase = .empty
            job = nil
            throw WorkspaceError.modelNotReady
        }

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
            throw error
        }
    }

    // MARK: - Shorts flow

    private func runShortsPipeline(job newJob: VideoJob, modelManager: ModelManager, settings: AppSettings,
                                   prefetchedTranscript: Transcript? = nil) async throws {
        cleanupClipTempFiles()
        job = newJob
        clips = []
        variants = []
        pipelineError = nil
        phase = .transcribing

        let pipelineStart = Date()
        Self.log("pipeline start — copywriter=\(settings.copywriterModel.rawValue)")
        do {
            // 1. Transcript: a pre-fetched one (YouTube CC) wins; else a sidecar
            //    .srt/.vtt; else on-device WhisperKit.
            phase = .transcribing
            let t0 = Date()
            let transcript: Transcript
            if let prefetchedTranscript {
                transcript = prefetchedTranscript
                Self.log("transcript: \(prefetchedTranscript.segments.count) pre-fetched cue(s) (YouTube CC) — Whisper skipped")
            } else {
                transcript = try await transcription.transcript(
                    for: newJob.url, languageHint: settings.languageOverride)
            }
            // Trust the language of the actual text over Whisper's 30s auto-detect.
            let captionLanguage = transcript.contentLanguage ?? transcript.language
            Self.log("transcript ready in \(Self.elapsed(since: t0)) — whisper=\(transcript.language ?? "?"), text=\(captionLanguage ?? "?")")
            try Task.checkCancellation()

            // On tight RAM, clear the decks before the heavy Director loads:
            // transcription is done, so free WhisperKit (~2 GB CoreML), and drop any
            // copywriter engine a prior caption job left resident. The Director then
            // loads into a clean memory state instead of on top of them.
            if MemoryPolicy.shouldFreeWhisperAfterTranscribe {
                transcription.unload()
            }
            modelManager.freeCopywriterIfMemoryTight()
            MemoryPolicy.releaseCaches()

            // Freeze the model choice for the whole run. Reading it once makes the
            // pipeline's memory plan (which model to load/free/when) immutable, so a
            // mid-run change in Settings can't strand a stage on a model that was
            // never loaded.
            let captioningModel = settings.copywriterModel

            // 2. Find the viral moments — one Director pass over the full transcript.
            phase = .findingMoments
            let t1 = Date()
            await modelManager.prepareDirector(profile: captioningModel.directorProfile)
            Self.log("director ready in \(Self.elapsed(since: t1)) — \(captioningModel.directorProfile.displayName)")
            // The two text models write the captions in this same pass.
            let useInlineCaptions = captioningModel.usesInlineCaptions
            let t2 = Date()
            let candidates = try await modelManager.momentFinder.findMoments(
                transcript: transcript.srtLike(),
                includeCaptions: useInlineCaptions,
                language: captionLanguage,
                styleExamples: settings.styleExamples)
            Self.log("found \(candidates.count) moment(s) in \(Self.elapsed(since: t2)), captions inline=\(useInlineCaptions) — \(MemoryPolicy.snapshot())")
            try Task.checkCancellation()

            // Seed cards; they fill in as each clip is cut + captioned.
            let captionStyle = CaptionStyle.preset(id: settings.captionStyleID)
            clips = candidates.map {
                ShortClip(candidate: $0,
                          transcriptSlice: transcript.slice(start: $0.start, end: $0.end),
                          wordStamps: transcript.wordStamps(start: $0.start, end: $0.end),
                          overlayEnabled: settings.burnHookOverlay,
                          reframeEnabled: settings.reframeToVertical,
                          captionsEnabled: settings.burnCaptions,
                          captionStyle: captionStyle)
            }
            phase = .shortsResults

            if useInlineCaptions {
                // The Director already wrote each clip's caption package in the
                // moment-finding pass — copy them over. If it occasionally dropped
                // one (truncation / malformed JSON), back-fill it NOW, while the
                // Director is still resident, with a per-clip text pass. Doing it
                // here (not in the cut loop) means we never reload a freed ~6 GB
                // model mid-pipeline on tight RAM.
                for (index, clip) in clips.enumerated() {
                    if !clip.candidate.variants.isEmpty {
                        clip.variants = clip.candidate.variants
                        clip.detectedLanguage = captionLanguage
                    } else if let result = try? await modelManager.momentFinder.caption(
                        transcriptSlice: clip.transcriptSlice,
                        hook: clip.candidate.hook,
                        languageOverride: effectiveLanguage(settings, captionLanguage),
                        styleExamples: settings.styleExamples) {
                        clip.variants = result.variants
                        clip.detectedLanguage = result.detectedLanguage
                        Self.log("clip \(index + 1)/\(clips.count) caption back-filled (Director dropped it inline)")
                    } else {
                        clip.detectedLanguage = captionLanguage
                    }
                }
            }

            // The Director's work is done. On tight RAM, free it now to hand its
            // memory back before the GPU-heavy cut + Vision reframe loop. The watch
            // path captions every clip with the separate E4B engine, so load that
            // lazily (16 GB skips the launch preload) right after.
            modelManager.freeDirectorIfMemoryTight()
            if captioningModel.watchesClips {
                await modelManager.prepareIfNeeded()
            }

            // 3+4. Cut, then caption, each clip in turn (one MLX engine → serial).
            // Inline clips are already captioned above, so the loop never reloads
            // the Director; only the watch path runs the E4B engine here.
            for (index, clip) in clips.enumerated() {
                try Task.checkCancellation()
                do {
                    clip.stage = .cutting
                    let tCut = Date()
                    let clipURL = try await MediaExtractor.cutClip(
                        from: newJob.url,
                        start: clip.candidate.start,
                        duration: clip.candidate.duration)
                    clip.clipJob = VideoJob(url: clipURL, durationSeconds: clip.candidate.duration)
                    // Only horizontal clips get the vertical-reframe option.
                    clip.isLandscape = await VerticalReframer.isLandscape(url: clipURL)

                    if !clip.variants.isEmpty || !captioningModel.watchesClips {
                        // Inline path: captions are set (or were unrecoverable — ship
                        // the clip anyway rather than reload a freed model).
                        clip.stage = .ready
                        Self.log("clip \(index + 1)/\(clips.count) ready — cut \(Self.elapsed(since: tCut)), captions inline")
                    } else {
                        // Watch path: caption this cut clip with the E4B engine.
                        clip.stage = .captioning
                        let tCap = Date()
                        let result = try await captionClip(
                            clip, model: captioningModel, modelManager: modelManager,
                            settings: settings, transcriptLanguage: captionLanguage)
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
            MemoryPolicy.releaseCaches()
            Self.log("pipeline done — \(clips.count) clip(s) in \(Self.elapsed(since: pipelineStart)) total — \(MemoryPolicy.snapshot())")
        } catch is CancellationError {
            cleanupClipTempFiles()
            clips = []
            self.job = nil
            phase = .empty
            throw CancellationError()
        } catch {
            pipelineError = error.localizedDescription
            errorMessage = "Couldn't make shorts from that video. \(error.localizedDescription)"
            self.job = nil
            clips = []
            phase = .empty
            throw error
        }
    }

    /// The caption output language: the user's manual override if set, else the
    /// language detected from the transcript text. Small captioners otherwise drift
    /// (e.g. Spanish → pt-BR), so we lock it.
    private func effectiveLanguage(_ settings: AppSettings, _ transcriptLanguage: String?) -> String {
        settings.languageOverride.trimmed.isEmpty
            ? (transcriptLanguage ?? "")
            : settings.languageOverride
    }

    /// Captions one cut clip with the frozen `model` (never `settings` directly, so
    /// a mid-run model change can't redirect this to a model that wasn't loaded).
    /// In practice only the watch path (E4B) reaches here — the inline path
    /// back-fills its captions while the Director is still resident. The Director
    /// branch is kept as a defensive fallback.
    private func captionClip(_ clip: ShortClip, model: AppSettings.CopywriterModel,
                             modelManager: ModelManager, settings: AppSettings,
                             transcriptLanguage: String?) async throws -> GenerationResult {
        let language = effectiveLanguage(settings, transcriptLanguage)

        switch model {
        case .gemmaE4B:
            guard let engine = modelManager.engine, let clipJob = clip.clipJob else {
                throw MomentFinderError.notReady
            }
            return try await GemmaService.generate(
                job: clipJob,
                engine: engine,
                languageOverride: language,
                styleExamples: settings.styleExamples)
        case .gemma12B, .qwen35_9b:
            await modelManager.prepareDirector(profile: model.directorProfile)
            return try await modelManager.momentFinder.caption(
                transcriptSlice: clip.transcriptSlice,
                hook: clip.candidate.hook,
                languageOverride: language,
                styleExamples: settings.styleExamples)
        }
    }

    func cancelPipeline() {
        pipelineTask?.cancel()
    }

    // MARK: - Timing logs (stderr; visible when launched from the terminal)

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[clipmunk/pipeline] \(message)\n".utf8))
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
        queue.removeAll()
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

    // MARK: - Library (History) + notifications

    /// Saves the just-finished shorts job to the on-device library (manifest +
    /// copied cut clips). A save failure is logged, never fatal.
    private func persistFinishedShortsJob(source: VideoJob) {
        let ready = clips.filter { if case .ready = $0.stage { return true } else { return false } }
        guard !ready.isEmpty else { return }

        var storedClips: [StoredClip] = []
        var clipSources: [String: URL] = [:]
        for clip in ready {
            let snapshot = clip.stored()
            storedClips.append(snapshot)
            if let url = clip.clipJob?.url { clipSources[snapshot.clipFile] = url }
        }
        let stored = StoredJob(
            id: UUID(), sourceFileName: source.fileName, createdAt: Date(),
            language: ready.first?.detectedLanguage, clips: storedClips)
        do {
            try JobLibrary.save(stored, clipSources: clipSources)
            library.insert(stored, at: 0)
        } catch {
            Self.log("library save failed: \(error.localizedDescription)")
        }
    }

    /// Reloads the persisted job list from disk (e.g. when opening History).
    func refreshLibrary() { library = JobLibrary.list() }

    /// Deletes a stored job (bundle + manifest) and drops it from History.
    func deleteLibraryJob(_ id: UUID) {
        JobLibrary.delete(id)
        library.removeAll { $0.id == id }
    }

    /// Reopens a stored job into the results grid for re-preview / re-download /
    /// re-publish. Skips clips whose copied video has gone missing.
    func reopen(_ stored: StoredJob) {
        pipelineTask?.cancel()
        cleanupClipTempFiles()
        queue.removeAll()
        clips = stored.clips.compactMap { sc in
            guard let url = try? JobLibrary.videoURL(jobID: stored.id, clipFile: sc.clipFile),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ShortClip(restoring: sc, clipURL: url)
        }
        job = VideoJob(url: URL(fileURLWithPath: stored.sourceFileName), durationSeconds: 0)
        detectedLanguage = stored.language
        pipelineError = nil
        errorMessage = nil
        phase = .shortsResults
    }

    /// Requests permission to post local notifications (called once at launch).
    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts a local notification now (no-op if the user declined authorization).
    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    enum WorkspaceError: LocalizedError {
        case modelNotReady
        case ytDlpMissing
        var errorDescription: String? {
            switch self {
            case .modelNotReady:
                "The model is still getting ready — give it a moment, then drop the video again."
            case .ytDlpMissing:
                "Downloading a YouTube video needs yt-dlp. Install it from the link field, then try again."
            }
        }
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
