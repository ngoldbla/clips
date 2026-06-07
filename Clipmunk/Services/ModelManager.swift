import Foundation
import Gemma4Swift
import Observation

/// Owns the Gemma 4 model lifecycle: first-run download, load, and the loaded
/// engine. Drives the download UI through `phase`.
@MainActor
@Observable
final class ModelManager {

    /// The model Clipmunk ships with: Gemma 4 E4B, 4-bit (~5 GB).
    static let model: Gemma4Pipeline.Model = .e4b4bit

    enum Phase: Equatable {
        case idle
        case downloading(fraction: Double, detail: String)
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var engine: Gemma4Engine?

    /// True once launch preparation has decided what (if anything) to preload, so
    /// the workspace can accept work. On 24 GB+ this waits for the copywriter to
    /// load (fast caption-a-short); on 16 GB it flips immediately and the
    /// copywriter loads lazily only when a flow needs it.
    private(set) var isLaunchComplete = false

    /// The "Director" — Qwen 3.5 9B, finds viral moments from a transcript.
    /// Loaded lazily on the first long-video drop, not at app launch.
    let momentFinder = MomentFinderService()

    // MARK: - Environment facts

    var systemRAMGB: Int { MemoryPolicy.systemRAMGB }
    var recommendedRAMGB: Int { Self.model.recommendedRAMGB }
    var hasEnoughRAM: Bool { systemRAMGB >= recommendedRAMGB }
    var isModelDownloaded: Bool { Gemma4ModelCache.isDownloaded(Self.model) }
    var estimatedDownloadGB: Int { Int(Self.model.estimatedSizeGB.rounded()) }

    /// True when there's room to keep both the copywriter and the Director
    /// resident at once. Below this we load them sequentially (free the Director
    /// before captioning) to avoid swapping/OOM.
    var canKeepBothResident: Bool { MemoryPolicy.canKeepBothResident }

    var isReady: Bool { engine != nil }
    var isBusy: Bool {
        switch phase {
        case .downloading, .loading: true
        default: false
        }
    }

    // MARK: - Lifecycle

    /// Called once at launch. On Macs with room (24 GB+) it preloads the
    /// multimodal copywriter so "Caption a short" is instant; on 16 GB it skips the
    /// preload entirely (the default shorts+inline flow never needs it) and just
    /// opens the workspace — the copywriter then loads lazily the first time a
    /// caption flow actually runs.
    func completeLaunch() async {
        if MemoryPolicy.shouldPreloadCopywriter {
            await prepareIfNeeded()
        }
        isLaunchComplete = true
    }

    /// Downloads (if needed) and loads the model. Safe to call repeatedly — it
    /// no-ops once the engine is ready or while work is already in flight.
    func prepareIfNeeded() async {
        guard engine == nil, !isBusy else { return }
        phase = isModelDownloaded ? .loading : .downloading(fraction: 0, detail: "Starting…")

        do {
            let prepared = try await Gemma4Engine.prepare(model: Self.model) { [weak self] stage in
                Task { @MainActor in
                    guard let self else { return }
                    switch stage {
                    case .downloading(let progress):
                        self.phase = .downloading(
                            fraction: progress.fraction,
                            detail: progress.formattedProgress)
                    case .loading:
                        self.phase = .loading
                    }
                }
            }
            engine = prepared
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Clears a failed state so the user can retry.
    func resetForRetry() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Director (moment finder)

    /// Loads the Director (the user's chosen text model — Gemma 4 12B by default,
    /// or Qwen 3.5 9B) if needed. Switches model first when the pick changed.
    /// Called from the shorts pipeline, not launch.
    func prepareDirector(profile: ChatModelProfile) async {
        momentFinder.setProfile(profile)
        await momentFinder.prepareIfNeeded()
    }

    /// Loads whichever Director model is currently selected.
    func prepareDirectorIfNeeded() async {
        await momentFinder.prepareIfNeeded()
    }

    /// Frees the Director to make room for the Gemma copywriter on tight RAM.
    func freeDirectorIfMemoryTight() {
        guard MemoryPolicy.isConstrained else { return }
        momentFinder.unload()
    }

    /// Frees the multimodal copywriter engine (Gemma E4B, ~5 GB) and its Metal
    /// cache on tight RAM, so a copywriter left resident by a prior caption job
    /// doesn't sit next to the Director during the shorts pipeline.
    func freeCopywriterIfMemoryTight() {
        guard MemoryPolicy.isConstrained, engine != nil else { return }
        engine = nil
        phase = .idle
        MemoryPolicy.releaseCaches()
    }
}
