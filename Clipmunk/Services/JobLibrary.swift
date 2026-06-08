import Foundation

/// Persisted state of one finished clip — enough to re-open the job for preview,
/// download, or publishing. The raw cut video is copied into the job bundle; the
/// reframe/caption/hook effects re-render on demand from these fields (the same
/// path the live grid uses), so reopened jobs stay fully editable.
struct StoredClip: Codable, Sendable {
    var candidate: ClipCandidate
    var transcriptSlice: String
    var captionScript: CaptionScript
    var variants: [PostVariant]
    var detectedLanguage: String?
    var overlayText: String
    var overlayEnabled: Bool
    var reframeEnabled: Bool
    var isLandscape: Bool
    var captionsEnabled: Bool
    var captionStyleID: String
    /// Faceless-voiceover state. Defaults make these optional to the synthesized
    /// Codable decoder, so pre-narration manifests still reopen cleanly.
    var narrationEnabled: Bool = false
    var narrationVoiceID: String = "af_heart"
    /// Filename of the copied raw cut, inside the bundle's `clips/` folder.
    var clipFile: String
    var durationSeconds: Double
}

/// A finished long-video job: its source reference and produced clips.
struct StoredJob: Codable, Sendable, Identifiable {
    var id: UUID
    var sourceFileName: String
    var createdAt: Date
    var language: String?
    var clips: [StoredClip]
}

/// On-device job library: one `<id>.clipmunk` bundle per finished job under
/// `~/Library/Application Support/Clipmunk/Library/`, holding a Codable
/// `manifest.json` plus the copied cut clips. Fully local — nothing leaves the
/// Mac. All file work is `nonisolated` (no main-actor hop for disk I/O).
enum JobLibrary {

    private static let manifestName = "manifest.json"
    private static let clipsDir = "clips"
    private static let bundleExt = "clipmunk"

    /// `~/Library/Application Support/Clipmunk/Library/`, created if needed.
    nonisolated static func root() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Clipmunk/Library", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func bundleURL(for id: UUID) throws -> URL {
        try root().appendingPathComponent("\(id.uuidString).\(bundleExt)", isDirectory: true)
    }

    /// The copied cut video for a stored clip.
    nonisolated static func videoURL(jobID: UUID, clipFile: String) throws -> URL {
        try bundleURL(for: jobID).appendingPathComponent(clipsDir).appendingPathComponent(clipFile)
    }

    /// Persists a job: copies each clip's cut video into the bundle, then writes
    /// the manifest. `clipSources` maps a clip's `clipFile` to the temp cut URL to
    /// copy from. Throws on I/O failure (the caller logs and keeps going — a
    /// failed save must not break the pipeline).
    nonisolated static func save(_ job: StoredJob, clipSources: [String: URL]) throws {
        let bundle = try bundleURL(for: job.id)
        let clips = bundle.appendingPathComponent(clipsDir, isDirectory: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)

        for clip in job.clips {
            guard let source = clipSources[clip.clipFile] else { continue }
            let dest = clips.appendingPathComponent(clip.clipFile)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: source, to: dest)
        }

        let data = try JSONEncoder().encode(job)
        try data.write(to: bundle.appendingPathComponent(manifestName), options: .atomic)
    }

    /// All stored jobs, newest first. Skips any bundle whose manifest is missing
    /// or unreadable rather than failing the whole list.
    nonisolated static func list() -> [StoredJob] {
        guard let dir = try? root(),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else { return [] }

        let decoder = JSONDecoder()
        return entries
            .filter { $0.pathExtension == bundleExt }
            .compactMap { bundle -> StoredJob? in
                let manifest = bundle.appendingPathComponent(manifestName)
                guard let data = try? Data(contentsOf: manifest),
                      let job = try? decoder.decode(StoredJob.self, from: data)
                else { return nil }
                return job
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    nonisolated static func delete(_ id: UUID) {
        if let bundle = try? bundleURL(for: id) {
            try? FileManager.default.removeItem(at: bundle)
        }
    }
}
