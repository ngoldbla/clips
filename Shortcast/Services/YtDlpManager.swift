import CryptoKit
import Foundation

/// Manages the **opt-in** `yt-dlp` binary used only when a YouTube video has no
/// captions to fetch directly and the user wants its video downloaded.
///
/// The core app ships with NO binary. The user explicitly opts in; we fetch the
/// official standalone `yt-dlp` build to Application Support, **verify its
/// checksum**, and run it via `Process` (the app isn't sandboxed; hardened
/// runtime is off). The downloaded mp4 then enters the existing pipeline
/// unchanged. We request a progressive mp4 so no FFmpeg merge is ever needed.
enum YtDlpManager {

    enum YtDlpError: LocalizedError {
        case notInstalled
        case checksumUnavailable
        case checksumMismatch
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:        "yt-dlp isn't installed yet."
            case .checksumUnavailable: "Couldn't verify the yt-dlp download (no published checksum)."
            case .checksumMismatch:    "The yt-dlp download failed its checksum check and was discarded."
            case .downloadFailed(let m): "yt-dlp couldn't download that video: \(m)"
            }
        }
    }

    private static let releaseBase = "https://github.com/yt-dlp/yt-dlp/releases/latest/download"
    private static let assetName = "yt-dlp_macos"

    /// Where our own copy lives once installed.
    static var installedURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Shortcast/bin/\(assetName)")
    }

    /// A usable yt-dlp path: our installed copy, or one already on PATH.
    static func resolve() -> URL? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: installedURL.path) { return installedURL }
        for path in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"]
        where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static var isAvailable: Bool { resolve() != nil }

    /// Downloads the official standalone `yt-dlp` binary, verifies it against the
    /// release's published SHA-256, and installs it executable to Application
    /// Support. Throws on any network or checksum failure (nothing is installed).
    static func install() async throws {
        guard let binURL = URL(string: "\(releaseBase)/\(assetName)"),
              let sumsURL = URL(string: "\(releaseBase)/SHA2-256SUMS")
        else { throw YtDlpError.downloadFailed("bad release URL") }

        let (tmpBin, _) = try await URLSession.shared.download(from: binURL)
        let binaryData = try Data(contentsOf: tmpBin)

        let (sumsData, _) = try await URLSession.shared.data(from: sumsURL)
        guard let sums = String(data: sumsData, encoding: .utf8),
              let expected = expectedHash(in: sums, for: assetName)
        else { throw YtDlpError.checksumUnavailable }

        let actual = SHA256.hash(data: binaryData).map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw YtDlpError.checksumMismatch
        }

        let fm = FileManager.default
        try fm.createDirectory(at: installedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: installedURL)
        try binaryData.write(to: installedURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedURL.path)
    }

    /// Downloads `videoURL`'s video as a progressive H.264 mp4 (no FFmpeg merge)
    /// into a temp file. Runs entirely inside a detached task so the non-Sendable
    /// `Process`/`Pipe` never cross an isolation boundary.
    static func downloadVideo(from videoURL: String) async throws -> URL {
        guard let bin = resolve() else { throw YtDlpError.notInstalled }
        return try await Task.detached(priority: .userInitiated) {
            let outDir = FileManager.default.temporaryDirectory
            let stem = "shortcast-yt-\(UUID().uuidString)"
            let template = outDir.appendingPathComponent("\(stem).%(ext)s").path

            let process = Process()
            process.executableURL = bin
            process.arguments = [
                "-f", "best[ext=mp4]/best",   // progressive single file → no merge
                "--no-playlist", "--no-progress", "--quiet", "--no-warnings",
                "-o", template, videoURL,
            ]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = pipe

            try process.run()
            process.waitUntilExit()
            let log = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw YtDlpError.downloadFailed(log.isEmpty ? "exit \(process.terminationStatus)" : log)
            }
            guard let produced = try FileManager.default.contentsOfDirectory(
                at: outDir, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.hasPrefix(stem) })
            else { throw YtDlpError.downloadFailed("no output file produced") }
            return produced
        }.value
    }

    /// Finds the expected hash for `name` in a `SHA2-256SUMS` file ("<hash>  <name>").
    private static func expectedHash(in sums: String, for name: String) -> String? {
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, String(parts[parts.count - 1]) == name {
                return String(parts[0])
            }
        }
        return nil
    }
}
