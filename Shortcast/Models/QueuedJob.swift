import Foundation
import Observation

/// One video waiting in (or moving through) the batch queue. Dropping several
/// videos at once enqueues one of these each; `WorkspaceModel` drains them
/// serially (the on-device MLX engine is single-instance, so serial is correct).
@MainActor
@Observable
final class QueuedJob: Identifiable {

    let id = UUID()
    /// A local file URL, or a YouTube watch URL when `youTubeID` is set.
    let url: URL
    let fileName: String
    /// Snapshotted at enqueue time so a later mode change doesn't reroute a job
    /// already waiting in line.
    let mode: WorkspaceModel.InputMode
    /// Set for YouTube jobs: the 11-char video id. The drainer downloads the
    /// video (opt-in yt-dlp) and fetches captions before running the pipeline.
    let youTubeID: String?

    enum Status: Equatable {
        case pending
        case processing
        case finished
        case failed(String)
    }
    var status: Status = .pending

    init(url: URL, mode: WorkspaceModel.InputMode, youTubeID: String? = nil) {
        self.url = url
        self.mode = mode
        self.youTubeID = youTubeID
        self.fileName = youTubeID.map { "YouTube · \($0)" } ?? url.lastPathComponent
    }
}
