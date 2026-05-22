import Foundation

/// The three social networks Shortcast publishes to.
enum SocialPlatform: String, CaseIterable, Codable, Identifiable, Sendable {
    case tiktok
    case instagram
    case youtube

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiktok:    "TikTok"
        case .instagram: "Instagram Reels"
        case .youtube:   "YouTube Shorts"
        }
    }

    /// Value expected by the Upload-Post `platform[]` form field.
    var uploadPostID: String { rawValue }

    /// SF Symbol used on the result card header.
    var symbolName: String {
        switch self {
        case .tiktok:    "music.note"
        case .instagram: "camera"
        case .youtube:   "play.rectangle.fill"
        }
    }

    /// Brand-ish accent as an sRGB hex string; the view turns it into a Color.
    var tintHex: String {
        switch self {
        case .tiktok:    "FF2D55"
        case .instagram: "C13584"
        case .youtube:   "FF0000"
        }
    }
}

/// One platform's proposed post. Edited in place by the user before publishing.
struct PostVariant: Identifiable, Codable, Sendable, Equatable {
    var platform: SocialPlatform
    /// Short title / scroll-stopping hook.
    var hook: String
    /// Body copy / caption.
    var summary: String
    /// Hashtags WITHOUT the leading `#` (normalized on parse).
    var hashtags: [String]

    var id: SocialPlatform { platform }

    /// Hashtags rendered as a single `#a #b #c` line.
    var hashtagLine: String {
        hashtags
            .map { $0.hasPrefix("#") ? $0 : "#\($0)" }
            .joined(separator: " ")
    }
}

/// Full result of one on-device generation pass.
struct GenerationResult: Sendable, Equatable {
    var variants: [PostVariant]
    /// Language the model wrote in (BCP-47-ish, e.g. "es", "en"). Informational.
    var detectedLanguage: String?

    func variant(for platform: SocialPlatform) -> PostVariant? {
        variants.first { $0.platform == platform }
    }
}
