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

    /// Upload-Post API key. Mirrored to `UserDefaults` on every change.
    var apiKey: String {
        didSet { persistAPIKey() }
    }

    /// Upload-Post profile name (from "Manage Users" — NOT a social handle).
    var profileName: String {
        didSet { defaults.set(profileName, forKey: Keys.profile) }
    }

    /// The language captions are written in. Defaults to "English" so output is
    /// English-only regardless of the spoken language; empty = match the video's
    /// language. Drives the Director's output language (see `effectiveLanguage`).
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

    /// Whether the Marlin-2B vision pass runs this session. It is the core
    /// perception layer — before the Director picks moments, Marlin watches the
    /// footage and hands it a timestamped "what's on screen, when" track (B-roll,
    /// on-screen text, scene changes) the transcript can't reveal. It is
    /// **mandatory**: there is no user toggle, so it always runs. A DEBUG-only env
    /// var (`CLIPMUNK_VISION_PASS=0`) skips it for the closed-loop
    /// baseline-vs-augmented A/B; in release it is always on.
    var effectiveVisionPass: Bool {
        #if DEBUG
        if let v = ProcessInfo.processInfo.environment["CLIPMUNK_VISION_PASS"] {
            return v == "1" || v.lowercased() == "true"
        }
        #endif
        return true
    }

    /// Default for replacing each short's audio with a synthesized voiceover
    /// ("faceless" mode). OFF by default — opt-in, per-clip overridable.
    var ttsEnabled: Bool {
        didSet { defaults.set(ttsEnabled, forKey: Keys.tts) }
    }

    /// Kokoro voice id used for narration (e.g. "af_heart").
    var ttsVoiceID: String {
        didSet { defaults.set(ttsVoiceID, forKey: Keys.ttsVoice) }
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
        // Default to English-only output; the user can switch to another language
        // or "match the video" (empty) in Settings.
        self.languageOverride = defaults.string(forKey: Keys.language) ?? "English"
        self.styleExamples = defaults.string(forKey: Keys.style) ?? ""
        // Defaults to true on first launch (no stored value yet).
        self.tiktokAsDraft = defaults.object(forKey: Keys.tiktokDraft) as? Bool ?? true
        // Default on — the user opted into the hook-overlay feature.
        self.burnHookOverlay = defaults.object(forKey: Keys.burnHook) as? Bool ?? true
        // Default on — horizontal clips should become vertical shorts.
        self.reframeToVertical = defaults.object(forKey: Keys.reframe) as? Bool ?? true
        // Default on — animated captions are the headline short-form look.
        self.burnCaptions = defaults.object(forKey: Keys.burnCaptions) as? Bool ?? true
        self.captionStyleID = defaults.string(forKey: Keys.captionStyle) ?? CaptionStyle.default.id
        // Off by default — opt-in network feature.
        self.youTubeIngestEnabled = defaults.object(forKey: Keys.youtube) as? Bool ?? false
        // Off by default — opt-in faceless voiceover (replaces clip audio).
        self.ttsEnabled = defaults.object(forKey: Keys.tts) as? Bool ?? false
        self.ttsVoiceID = defaults.string(forKey: Keys.ttsVoice) ?? VoiceCatalog.defaultVoiceID
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
        static let burnHook    = "clipmunk.burnHookOverlay"
        static let reframe     = "clipmunk.reframeToVertical"
        static let burnCaptions = "clipmunk.burnCaptions"
        static let captionStyle = "clipmunk.captionStyleID"
        static let youtube     = "clipmunk.youTubeIngestEnabled"
        static let tts         = "clipmunk.ttsEnabled"
        static let ttsVoice    = "clipmunk.ttsVoiceID"
        static let apiKey      = "clipmunk.apiKey"
        /// Old Keychain account, read once to migrate into UserDefaults.
        static let legacyApiKey = "upload-post-api-key"
    }
}
