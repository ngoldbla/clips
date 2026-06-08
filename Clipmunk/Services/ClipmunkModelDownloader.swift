import CryptoKit
import Foundation
import MLXLMCommon

/// Drop-in replacement for MLX's `#hubDownloader()` that does NOT route through
/// swift-huggingface's snapshot downloader.
///
/// Why this exists: swift-huggingface 0.9.0 (with the `Xet` trait compiled out, as
/// it is in this build) downloads large weight files over its classic LFS path on a
/// `URLSession(configuration: .default)` that configures **no transfer/stall
/// timeout** — `timeoutIntervalForResource` defaults to 7 days and
/// `timeoutIntervalForRequest` is reset by the cross-host CDN redirect, so a stalled
/// connection to HuggingFace's Xet CAS bridge hangs essentially forever with no
/// error. The small config/tokenizer files land fine; the multi-GB
/// `model.safetensors` freezes at 0% — the exact symptom on the Gemma 4 E2B
/// Director. A plain redirect-following `GET` of the same `resolve` URL downloads the
/// full reconstructed file at full speed, which is precisely what this downloader
/// does.
///
/// It conforms to `MLXLMCommon.Downloader`, so it is a literal drop-in for the
/// `#hubDownloader()` macro: swap the one line and every call site keeps working.
/// It streams each file to disk (never buffers GB in RAM), resumes interrupted
/// transfers with HTTP `Range`, verifies LFS files by sha256, reports byte-accurate
/// progress, and returns a flat local directory the MLX loaders
/// (`loadModelContainer(from:)` / `VLMModelFactory.loadContainer(from:)`) consume
/// verbatim — no HuggingFace `snapshots/<hash>` layout required.
struct ClipmunkModelDownloader: MLXLMCommon.Downloader {

    /// Optional HuggingFace bearer token, for gated repos. `nil` for the public
    /// Director repo (downloads anonymously).
    var token: String?

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await HubSnapshotDownloader(token: token).download(
            repo: id,
            revision: revision ?? "main",
            patterns: patterns,
            force: useLatest,
            progressHandler: progressHandler)
    }
}

// MARK: - Errors

enum HubDownloadError: LocalizedError {
    case invalidRepoID(String)
    case apiUnreachable(String, Int)
    case apiUnparseable(String)
    case gatedRepo(String)
    case noMatchingFiles(String)
    case httpError(file: String, status: Int)
    case sizeMismatch(file: String, expected: Int64, got: Int64)
    case checksumMismatch(file: String)

    var errorDescription: String? {
        switch self {
        case .invalidRepoID(let id):
            return "Invalid model repository id '\(id)'."
        case .apiUnreachable(let id, let code):
            return "Couldn't reach Hugging Face for \(id) (HTTP \(code))."
        case .apiUnparseable(let id):
            return "Couldn't read the file list for \(id)."
        case .gatedRepo(let id):
            return "Access to the model \(id) is restricted (gated). Sign in to Hugging Face and request access, or switch to an open mirror."
        case .noMatchingFiles(let id):
            return "No downloadable files found for \(id)."
        case .httpError(let file, let status):
            return "Download failed for \(file) (HTTP \(status))."
        case .sizeMismatch(let file, let expected, let got):
            return "Downloaded \(file) is the wrong size (expected \(expected) bytes, got \(got))."
        case .checksumMismatch(let file):
            return "Downloaded \(file) failed its integrity check — it's incomplete or corrupted."
        }
    }
}

// MARK: - Snapshot downloader

/// Downloads the matching files of one HuggingFace repo snapshot into the local
/// model cache (`~/Library/Caches/models/{org}/{model}`) and returns that directory.
/// Sequential, resumable, integrity-checked.
final class HubSnapshotDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let token: String?

    /// Per-file retry attempts for transient stalls/drops (each retry resumes from
    /// the partial `.part` file, so we never re-download bytes we already have).
    private let maxAttemptsPerFile = 4

    // MARK: One in-flight file at a time (downloads are strictly sequential).
    private let lock = NSLock()
    private var handle: FileHandle?
    private var sentRangeHeader = false              // did this request ask to resume?
    private var continuation: CheckedContinuation<Void, Error>?
    private var fileProgress: (@Sendable (Int64) -> Void)?   // absolute bytes-for-this-file

    /// Dedicated session for file transfers (delegate = self, with a real timeout).
    private lazy var fileSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        // The crux of the fix: a real inactivity watchdog. This interval is the
        // time to wait for *additional* data and is reset on every byte, so a
        // genuinely stalled transfer surfaces as `URLError.timedOut` instead of
        // hanging forever (the swift-huggingface failure mode).
        cfg.timeoutIntervalForRequest = 120
        // Whole-file ceiling — generous enough for a 4.5 GB file on a slow link.
        cfg.timeoutIntervalForResource = 6 * 3600
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    /// Separate, delegate-less session for the small JSON manifest call (so the
    /// async `data(for:)` convenience never trips the file-transfer delegate).
    private lazy var apiSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    init(token: String?) {
        self.token = token
        super.init()
    }

    // No `deinit`-based teardown: `fileSession` holds a strong reference to its
    // delegate (`self`), so relying on `deinit` to invalidate it would be a retain
    // cycle that never fires. Instead `download(...)` invalidates both sessions in a
    // `defer` once the work is done, which breaks the cycle deterministically.

    // MARK: - Public

    func download(
        repo: String,
        revision: String,
        patterns: [String],
        force: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else { throw HubDownloadError.invalidRepoID(repo) }

        // Same cache root the vendored Gemma4Swift uses (`~/Library/Caches/models`),
        // so anything it already downloaded is reused and vice-versa.
        var modelDir = Self.modelsRoot
        for part in parts { modelDir = modelDir.appendingPathComponent(String(part)) }

        // Offline-after-first-use: everything already present → return immediately,
        // no network. (Skipped when `force`, which is `useLatest` from the caller.)
        // Checked before the sessions are lazily created, so the fast path stays
        // network- and allocation-free.
        if !force, Self.hasModelFiles(at: modelDir) {
            emit(progressHandler, completed: 1, total: 1)
            return modelDir
        }

        // We're going to do network work: ensure both sessions are torn down on
        // every exit path. Invalidating `fileSession` releases its strong hold on
        // `self` (the delegate), so this instance can actually deallocate.
        defer {
            fileSession.invalidateAndCancel()
            apiSession.invalidateAndCancel()
        }

        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        // 1. One API call: file list + sizes + sha256 + the resolved commit.
        let manifest = try await fetchManifest(repo: repo, revision: revision)
        let wanted = manifest.files.filter { file in
            patterns.contains { Self.glob($0, matches: file.name) }
        }
        guard !wanted.isEmpty else { throw HubDownloadError.noMatchingFiles(repo) }

        // Aggregate total. When the API omits a size (rare; small non-LFS files),
        // assume ~1 MB so the bar total stays sane and monotonic.
        func padded(_ size: Int64) -> Int64 { size > 0 ? size : 1_048_576 }
        let totalBytes = max(wanted.reduce(Int64(0)) { $0 + padded($1.size) }, 1)
        var completedBytes: Int64 = 0
        emit(progressHandler, completed: 0, total: totalBytes)

        // 2. Download each file in sequence, resuming partials, verifying sha256.
        for file in wanted {
            try Task.checkCancellation()
            let destination = modelDir.appendingPathComponent(file.name)

            // Already complete (right size, or unknown size but present)?
            if !force, let done = Self.completedSize(at: destination),
               file.size <= 0 || done == file.size {
                completedBytes += padded(file.size)
                emit(progressHandler, completed: completedBytes, total: totalBytes)
                continue
            }

            let base = completedBytes
            try await downloadFile(
                repo: repo,
                commit: manifest.commit,
                file: file,
                destination: destination,
                onProgress: { absolute in
                    self.emit(progressHandler, completed: base + absolute, total: totalBytes)
                })

            completedBytes += padded(file.size)
            emit(progressHandler, completed: completedBytes, total: totalBytes)
        }

        emit(progressHandler, completed: totalBytes, total: totalBytes)
        return modelDir
    }

    // MARK: - Manifest

    private struct FileEntry {
        let name: String
        let size: Int64        // <= 0 when unknown
        let sha256: String?    // LFS files only
    }
    private struct Manifest {
        let commit: String     // resolved commit hash (pins resolve URLs)
        let files: [FileEntry]
    }

    private func fetchManifest(repo: String, revision: String) async throws -> Manifest {
        let base = "https://huggingface.co/api/models/\(repo)"
        let urlString = revision == "main"
            ? "\(base)?blobs=true"
            : "\(base)/revision/\(revision)?blobs=true"
        guard let url = URL(string: urlString) else { throw HubDownloadError.invalidRepoID(repo) }

        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await apiSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw HubDownloadError.gatedRepo(repo) }
        guard status == 200 else { throw HubDownloadError.apiUnreachable(repo, status) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HubDownloadError.apiUnparseable(repo)
        }
        let commit = (json["sha"] as? String) ?? revision
        guard let siblings = json["siblings"] as? [[String: Any]] else {
            throw HubDownloadError.apiUnparseable(repo)
        }
        let files: [FileEntry] = siblings.compactMap { sib in
            guard let name = sib["rfilename"] as? String else { return nil }
            let lfs = sib["lfs"] as? [String: Any]
            let size = (lfs?["size"] as? NSNumber)?.int64Value
                ?? (sib["size"] as? NSNumber)?.int64Value
                ?? -1
            let sha = lfs?["sha256"] as? String
            return FileEntry(name: name, size: size, sha256: sha)
        }
        return Manifest(commit: commit, files: files)
    }

    // MARK: - Per-file download (with resume + verify + retry)

    private func downloadFile(
        repo: String,
        commit: String,
        file: FileEntry,
        destination: URL,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let part = destination.appendingPathExtension("part")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var lastError: Error?
        for attempt in 1...maxAttemptsPerFile {
            try Task.checkCancellation()
            do {
                try await fetchOnce(
                    repo: repo, commit: commit, file: file, part: part, onProgress: onProgress)

                // Verify size when known.
                let finalSize = Self.completedSize(at: part) ?? -1
                if file.size > 0, finalSize != file.size {
                    throw HubDownloadError.sizeMismatch(file: file.name, expected: file.size, got: finalSize)
                }
                // Verify sha256 for LFS files.
                if let sha = file.sha256,
                   try Self.sha256(of: part).compare(sha, options: .caseInsensitive) != .orderedSame {
                    try? FileManager.default.removeItem(at: part)
                    throw HubDownloadError.checksumMismatch(file: file.name)
                }
                // Install atomically.
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: part, to: destination)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HubDownloadError {
                lastError = error
                switch error {
                case .gatedRepo, .httpError:
                    throw error   // won't fix on retry of the same source
                default:
                    // size/checksum failure: a corrupt partial — clear and re-pull.
                    try? FileManager.default.removeItem(at: part)
                }
            } catch {
                // Transient (timeout, connection drop): keep `.part` and resume.
                lastError = error
            }
            if attempt < maxAttemptsPerFile {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
        throw lastError ?? HubDownloadError.httpError(file: file.name, status: 0)
    }

    /// One GET attempt, appending to `part` from wherever it left off.
    private func fetchOnce(
        repo: String,
        commit: String,
        file: FileEntry,
        part: URL,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let have = Self.completedSize(at: part) ?? 0

        // Re-derive the resolve URL every attempt: the redirect lands on a
        // time-limited presigned CDN URL, so a stale one can't be reused.
        let urlString = "https://huggingface.co/\(repo)/resolve/\(commit)/\(file.name)"
        guard let url = URL(string: urlString) else {
            throw HubDownloadError.httpError(file: file.name, status: 0)
        }
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }

        if have == 0 { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let fh = try FileHandle(forWritingTo: part)
        try fh.seekToEnd()

        lock.withLock {
            self.handle = fh
            self.sentRangeHeader = have > 0
            self.fileProgress = onProgress
        }

        let task = fileSession.dataTask(with: request)

        defer {
            try? fh.close()
            lock.withLock {
                self.handle = nil
                self.fileProgress = nil
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.withLock { self.continuation = cont }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 416 {
            // Range not satisfiable — the partial already holds the full file.
            completionHandler(.cancel)
            resumeContinuation(with: nil)
            return
        }
        if status == 401 || status == 403 {
            completionHandler(.cancel)
            let name = dataTask.originalRequest?.url?.lastPathComponent ?? ""
            resumeContinuation(with: HubDownloadError.gatedRepo(name))
            return
        }
        guard (200...299).contains(status) else {
            completionHandler(.cancel)
            let name = dataTask.originalRequest?.url?.lastPathComponent ?? ""
            resumeContinuation(with: HubDownloadError.httpError(file: name, status: status))
            return
        }

        // If we asked to resume (Range) but the server ignored it and returned the
        // whole file (200 instead of 206), discard the partial and write from 0.
        lock.lock()
        if sentRangeHeader, status == 200 {
            try? handle?.truncate(atOffset: 0)
            try? handle?.seek(toOffset: 0)
        }
        sentRangeHeader = false
        lock.unlock()

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let fh = handle
        let report = fileProgress
        lock.unlock()
        guard let fh else { return }
        do {
            try fh.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            resumeContinuation(with: error)
            return
        }
        // On-disk size is the absolute bytes-for-this-file (includes any resumed
        // prefix; or starts at 0 after a truncate). Report it to the aggregate.
        let onDisk = (try? fh.offset()).map(Int64.init) ?? 0
        report?(onDisk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        resumeContinuation(with: error)
    }

    // MARK: - Continuation plumbing

    private func resumeContinuation(with error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        guard let cont else { return }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            cont.resume(throwing: CancellationError())
        } else if let error {
            cont.resume(throwing: error)
        } else {
            cont.resume()
        }
    }

    // MARK: - Helpers

    private func emit(_ handler: @Sendable @escaping (Progress) -> Void, completed: Int64, total: Int64) {
        let p = Progress(totalUnitCount: max(total, 1))
        p.completedUnitCount = max(0, min(completed, total))
        handler(p)
    }

    /// `~/Library/Caches/models` — matches `Gemma4ModelCache.modelsDirectory` so the
    /// app and the vendored runtime share one model cache.
    static var modelsRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)
    }

    static func hasModelFiles(at dir: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { return false }
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    /// On-disk size of a file (nil if missing).
    static func completedSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// Streaming SHA-256 of a file (chunked — never loads the whole file in RAM).
    static func sha256(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 4 * 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Minimal glob via `fnmatch` (handles the HF patterns like `*.safetensors`).
    static func glob(_ pattern: String, matches name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}
