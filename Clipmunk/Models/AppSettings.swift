import Foundation
import Observation

/// User configuration: Upload-Post credentials and content-style preferences.
///
/// Everything (including the API key) lives in `UserDefaults`. The key used to
/// sit in the Keychain, but every dev rebuild changes the app's code signature,
/// so macOS re-prompted on each launch — for a 100% local/offline tool the
/// plist is a fine home. Held as an `@Observable` so views update on change.
@MainActor
@Observable
final class AppSettings {

    /// Which model finds the moments and writes each clip's captions. Two of the
    /// options (Gemma 4 12B, Qwen 3.5 9B) are text models that double as the
    /// "Director" and write captions inline in the same pass; the third (Gemma 4
    /// E4B) is a multimodal copywriter that watches each clip separately.
    enum CopywriterModel: String, CaseIterable, Identifiable, Sendable {
        case gemma12B = "gemma12b"
        case qwen35_9b = "qwen"
        case gemmaE4B = "gemma"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .gemma12B:  "Gemma 4 12B"
            case .qwen35_9b: "Qwen 3.5 9B"
            case .gemmaE4B:  "Gemma 4 E4B · 4-bit"
            }
        }

        var tagline: String {
            switch self {
            case .gemma12B:  "Finds the moments AND writes all three captions in one pass — strongest writing, one model, keeps the spoken language."
            case .qwen35_9b: "Finds the moments AND writes all three captions in one pass — lighter, one model, keeps the spoken language."
            case .gemmaE4B:  "Watches each clip (frames + audio) and captions it in a separate pass per clip."
            }
        }

        /// The text model that finds the moments. The two inline options are
        /// their own Director; the clip-watching option still needs a Director,
        /// for which we use the default (Gemma 4 12B).
        var directorProfile: ChatModelProfile {
            switch self {
            case .qwen35_9b:           .qwen35_9b
            case .gemma12B, .gemmaE4B: .gemma12B
            }
        }

        /// True when the Director writes the captions in the same pass (so no
        /// separate per-clip captioning step runs).
        var usesInlineCaptions: Bool {
            switch self {
            case .gemma12B, .qwen35_9b: true
            case .gemmaE4B:             false
            }
        }

        /// True for the multimodal Gemma E4B path that watches each clip — the
        /// only option that loads a second model alongside the Director.
        var watchesClips: Bool { self == .gemmaE4B }

        /// First-launch default, sized to this Mac's memory. The 12B Director needs
        /// ~13 GB resident and swaps hard on 16 GB; Qwen 3.5 9B (~6 GB) fits and runs
        /// the same one-pass inline-caption flow with a huge context window. 24 GB+
        /// gets the stronger 12B. Only used when the user hasn't picked explicitly.
        static var ramAdaptiveDefault: CopywriterModel {
            MemoryPolicy.canKeepBothResident ? .gemma12B : .qwen35_9b
        }
    }

    /// Upload-Post API key. Mirrored to `UserDefaults` on every change.
    var apiKey: String {
        didSet { persistAPIKey() }
    }

    /// Upload-Post profile name (from "Manage Users" — NOT a social handle).
    var profileName: String {
        didSet { defaults.set(profileName, forKey: Keys.profile) }
    }

    /// Optional caption language override (e.g. "English", "es"). Empty = match
    /// the language spoken in the video.
    var languageOverride: String {
        didSet { defaults.set(languageOverride, forKey: Keys.language) }
    }

    /// Optional examples of the user's own captions, fed to the model as style.
    var styleExamples: String {
        didSet { defaults.set(styleExamples, forKey: Keys.style) }
    }

    /// When true, TikTok uploads land in the inbox as a draft instead of
    /// publishing directly (`post_mode=MEDIA_UPLOAD`). On by default.
    var tiktokAsDraft: Bool {
        didSet { defaults.set(tiktokAsDraft, forKey: Keys.tiktokDraft) }
    }

    /// The Copywriter model used to caption generated shorts.
    var copywriterModel: CopywriterModel {
        didSet { defaults.set(copywriterModel.rawValue, forKey: Keys.copywriter) }
    }

    /// Default for burning an AI text hook into the top of each generated short.
    /// Per-clip toggles can override this.
    var burnHookOverlay: Bool {
        didSet { defaults.set(burnHookOverlay, forKey: Keys.burnHook) }
    }

    /// Default for reframing a horizontal (16:9) clip to vertical 9:16, tracking
    /// the speaker with Vision. Only applies to clips that are actually
    /// landscape; per-clip toggles can override this.
    var reframeToVertical: Bool {
        didSet { defaults.set(reframeToVertical, forKey: Keys.reframe) }
    }

    /// Default for burning animated word-level captions into each generated
    /// short. Per-clip toggles can override this.
    var burnCaptions: Bool {
        didSet { defaults.set(burnCaptions, forKey: Keys.burnCaptions) }
    }

    /// Which caption look to use, by `CaptionStyle` preset id (e.g. "bold-white",
    /// "hormozi", "pop", "clean").
    var captionStyleID: String {
        didSet { defaults.set(captionStyleID, forKey: Keys.captionStyle) }
    }

    /// Opt-in: allow pasting a YouTube link. Fetches captions directly over the
    /// network and uses an opt-in `yt-dlp` to download the video. OFF by default
    /// — it's the only feature that adds outbound traffic during processing, so
    /// the app keeps its "nothing leaves your Mac" posture unless you enable it.
    var youTubeIngestEnabled: Bool {
        didSet { defaults.set(youTubeIngestEnabled, forKey: Keys.youtube) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // API key now lives in UserDefaults. If a value is still in the Keychain
        // from an older build, migrate it once and clear it from the Keychain.
        if let stored = defaults.string(forKey: Keys.apiKey), !stored.isEmpty {
            self.apiKey = stored
        } else if let legacy = KeychainStore.read(account: Keys.legacyApiKey),
                  !legacy.isEmpty {
            self.apiKey = legacy
            defaults.set(legacy, forKey: Keys.apiKey)
            KeychainStore.delete(account: Keys.legacyApiKey)
        } else {
            self.apiKey = ""
        }
        self.profileName = defaults.string(forKey: Keys.profile) ?? ""
        self.languageOverride = defaults.string(forKey: Keys.language) ?? ""
        self.styleExamples = defaults.string(forKey: Keys.style) ?? ""
        // Defaults to true on first launch (no stored value yet).
        self.tiktokAsDraft = defaults.object(forKey: Keys.tiktokDraft) as? Bool ?? true
        // One text model finds the moments and writes the captions in the same
        // pass, keeping the spoken language. The first-launch default is sized to
        // this Mac's RAM (Qwen 3.5 9B on 16 GB, Gemma 4 12B on 24 GB+); an explicit
        // pick in Settings always wins.
        self.copywriterModel = defaults.string(forKey: Keys.copywriter)
            .flatMap(CopywriterModel.init) ?? CopywriterModel.ramAdaptiveDefault
        // Default on — the user opted into the hook-overlay feature.
        self.burnHookOverlay = defaults.object(forKey: Keys.burnHook) as? Bool ?? true
        // Default on — horizontal clips should become vertical shorts.
        self.reframeToVertical = defaults.object(forKey: Keys.reframe) as? Bool ?? true
        // Default on — animated captions are the headline short-form look.
        self.burnCaptions = defaults.object(forKey: Keys.burnCaptions) as? Bool ?? true
        self.captionStyleID = defaults.string(forKey: Keys.captionStyle) ?? CaptionStyle.default.id
        // Off by default — opt-in network feature.
        self.youTubeIngestEnabled = defaults.object(forKey: Keys.youtube) as? Bool ?? false
    }

    /// True once the app has enough to publish.
    var isConfigured: Bool {
        !apiKey.trimmed.isEmpty && !profileName.trimmed.isEmpty
    }

    private func persistAPIKey() {
        let trimmed = apiKey.trimmed
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Keys.apiKey)
        } else {
            defaults.set(trimmed, forKey: Keys.apiKey)
        }
    }

    private enum Keys {
        static let profile     = "clipmunk.profileName"
        static let language    = "clipmunk.languageOverride"
        static let style       = "clipmunk.styleExamples"
        static let tiktokDraft = "clipmunk.tiktokAsDraft"
        static let copywriter  = "clipmunk.copywriterModel"
        static let burnHook    = "clipmunk.burnHookOverlay"
        static let reframe     = "clipmunk.reframeToVertical"
        static let burnCaptions = "clipmunk.burnCaptions"
        static let captionStyle = "clipmunk.captionStyleID"
        static let youtube     = "clipmunk.youTubeIngestEnabled"
        static let apiKey      = "clipmunk.apiKey"
        /// Old Keychain account, read once to migrate into UserDefaults.
        static let legacyApiKey = "upload-post-api-key"
    }
}
