import Foundation

/// Fetches a YouTube video's existing closed captions directly and maps them to
/// a `Transcript`, so a video that already has captions skips the on-device
/// Whisper model entirely. This is an EXPLICIT network call — the only outbound
/// traffic during processing — surfaced in the UI and kept behind the opt-in
/// YouTube feature. Returns `nil` when the video has no usable caption track
/// (the caller then falls back to Whisper on the downloaded file).
enum YouTubeIngest {

    /// Extracts the 11-character video id from a watch URL, share link, /shorts/
    /// link, embed link, or a bare id.
    static func videoID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
            return trimmed
        }
        let patterns = ["v=([A-Za-z0-9_-]{11})", "youtu\\.be/([A-Za-z0-9_-]{11})",
                        "/shorts/([A-Za-z0-9_-]{11})", "/embed/([A-Za-z0-9_-]{11})",
                        "/v/([A-Za-z0-9_-]{11})", "/live/([A-Za-z0-9_-]{11})"]
        for pattern in patterns {
            if let range = trimmed.range(of: pattern, options: .regularExpression) {
                let match = String(trimmed[range])
                if let idRange = match.range(of: "[A-Za-z0-9_-]{11}$", options: .regularExpression) {
                    return String(match[idRange])
                }
            }
        }
        return nil
    }

    /// True when the input is a YouTube link we can ingest (domain + valid id).
    static func looksLikeYouTube(_ input: String) -> Bool {
        let lower = input.lowercased()
        return (lower.contains("youtube.com") || lower.contains("youtu.be")) && videoID(from: input) != nil
    }

    static func watchURLString(id: String) -> String { "https://www.youtube.com/watch?v=\(id)" }

    enum IngestError: LocalizedError {
        case fetchFailed(String)
        var errorDescription: String? {
            switch self { case .fetchFailed(let m): "Couldn't fetch YouTube captions: \(m)" }
        }
    }

    /// Fetches captions for `videoID` and maps them to a cue-level `Transcript`
    /// (Phase 1's per-word synthesis fills in word timing). `nil` = no captions.
    static func fetchTranscript(videoID: String, languageHint: String = "") async throws -> Transcript? {
        guard let url = URL(string: watchURLString(id: videoID)) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)",
            forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw IngestError.fetchFailed("watch page unreadable")
        }
        guard let player = extractPlayerResponse(from: html),
              let tracks = captionTracks(in: player), !tracks.isEmpty
        else { return nil }   // no captions available

        let track = chooseTrack(tracks, languageHint: languageHint)
        guard let baseUrl = track["baseUrl"] as? String,
              let ttURL = URL(string: baseUrl + "&fmt=json3")
        else { return nil }

        let (ttData, _) = try await URLSession.shared.data(from: ttURL)
        let segments = parseJSON3(ttData)
        guard !segments.isEmpty else { return nil }
        return Transcript(segments: segments, language: track["languageCode"] as? String)
    }

    // MARK: - Parsing (mirrors the tolerant balanced-brace scan used elsewhere)

    private static func extractPlayerResponse(from html: String) -> [String: Any]? {
        guard let marker = html.range(of: "ytInitialPlayerResponse"),
              let braceStart = html[marker.upperBound...].firstIndex(of: "{"),
              let json = balancedObject(html, from: braceStart),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Returns the balanced `{…}` substring starting at `start`, respecting strings.
    private static func balancedObject(_ s: String, from start: String.Index) -> String? {
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return String(s[start...i]) } }
            i = s.index(after: i)
        }
        return nil
    }

    private static func captionTracks(in player: [String: Any]) -> [[String: Any]]? {
        let captions = player["captions"] as? [String: Any]
        let renderer = captions?["playerCaptionsTracklistRenderer"] as? [String: Any]
        return renderer?["captionTracks"] as? [[String: Any]]
    }

    private static func chooseTrack(_ tracks: [[String: Any]], languageHint: String) -> [String: Any] {
        let hint = languageHint.lowercased().prefix(2)
        if !hint.isEmpty,
           let match = tracks.first(where: { ($0["languageCode"] as? String)?.lowercased().hasPrefix(hint) == true }) {
            return match
        }
        if let english = tracks.first(where: { ($0["languageCode"] as? String)?.hasPrefix("en") == true }) {
            return english
        }
        return tracks[0]
    }

    private static func parseJSON3(_ data: Data) -> [TranscriptSegment] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = obj["events"] as? [[String: Any]] else { return [] }
        var segments: [TranscriptSegment] = []
        for event in events {
            guard let segs = event["segs"] as? [[String: Any]] else { continue }
            let text = segs.compactMap { $0["utf8"] as? String }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let startMs = number(event["tStartMs"])
            let durMs = number(event["dDurationMs"])
            let start = startMs / 1000
            segments.append(TranscriptSegment(start: start, end: max(start, (startMs + durMs) / 1000), text: text))
        }
        return segments
    }

    private static func number(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return 0
    }
}
