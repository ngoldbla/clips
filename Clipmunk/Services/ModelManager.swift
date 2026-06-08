import Foundation
import Observation

/// Owns the on-device model lifecycle: the Director (Gemma 4 E2B — finds moments
/// and writes captions from a transcript) and the optional Marlin-2B vision pass.
/// Both load lazily on the first job; nothing downloads at app launch.
@MainActor
@Observable
final class ModelManager {

    /// True once launch preparation is done so the workspace can accept work.
    /// There is nothing to preload — the Director loads lazily on the first job —
    /// so this flips immediately. Kept as a seam for any future launch-time work.
    private(set) var isLaunchComplete = false

    /// The "Director" — Gemma 4 E2B, finds viral moments and writes each clip's
    /// captions from the transcript. Loaded lazily on the first job.
    let momentFinder = MomentFinderService()

    /// The perception layer — Marlin-2B watches the video and produces a
    /// timestamped on-screen track for the Director. Loaded lazily, only when the
    /// vision pass runs, and freed before the Director loads (one large model at a
    /// time on tight RAM). ~2.5 GB resident.
    let visualMapper = VisualMapper()

    // MARK: - Environment facts

    var systemRAMGB: Int { MemoryPolicy.systemRAMGB }

    // MARK: - Lifecycle

    /// Called once at launch. Nothing is preloaded (the Director loads on the first
    /// job), so this just opens the workspace.
    func completeLaunch() async {
        isLaunchComplete = true
    }

    // MARK: - Director (moment finder)

    /// Loads the Director (Gemma 4 E2B) if needed. Switches model first when the
    /// profile changed. Called from the pipeline, not launch.
    func prepareDirector(profile: ChatModelProfile) async {
        momentFinder.setProfile(profile)
        await momentFinder.prepareIfNeeded()
    }

    /// Loads the Director model if it isn't resident yet.
    func prepareDirectorIfNeeded() async {
        await momentFinder.prepareIfNeeded()
    }

    /// Frees the Director to hand its memory back before the GPU-heavy cut + Vision
    /// reframe loop on a memory-constrained Mac.
    func freeDirectorIfMemoryTight() {
        guard MemoryPolicy.isConstrained else { return }
        momentFinder.unload()
    }

    // MARK: - Visual mapper (perception layer)

    /// Loads Marlin if needed for the vision pass. Called from the shorts pipeline
    /// before the Director, only when the vision pass is enabled.
    func prepareVisualMapperIfNeeded() async {
        await visualMapper.prepareIfNeeded()
    }

    /// Frees Marlin (~2.5 GB) right after the vision pass so the Director loads
    /// into a clean memory state on a 16 GB Mac (one large model at a time).
    func freeVisualMapper() {
        visualMapper.unload()
        MemoryPolicy.releaseCaches()
    }
}
