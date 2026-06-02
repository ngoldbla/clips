import Foundation
import Observation

/// User configuration: Upload-Post credentials and content-style preferences.
///
/// The API key is persisted in the macOS Keychain; everything else lives in
/// `UserDefaults`. Held as an `@Observable` so SwiftUI views update on change.
@MainActor
@Observable
final class AppSettings {

    /// Which model writes each clip's captions (the "Copywriter"). The Director
    /// that finds moments is always Qwen 3.5 9B and is not selectable.
    enum CopywriterModel: String, CaseIterable, Identifiable, Sendable {
        case gemmaE4B = "gemma"
        case qwen35_9b = "qwen"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .gemmaE4B:  "Gemma 4 E4B · 4-bit"
            case .qwen35_9b: "Qwen 3.5 9B"
            }
        }

        var tagline: String {
            switch self {
            case .gemmaE4B:  "Watches each clip (frames + audio). Lighter on memory."
            case .qwen35_9b: "Writes from the clip's transcript. Reuses the Director — one model for everything."
            }
        }
    }

    /// Upload-Post API key. Stored property (so views can bind to it) but
    /// mirrored to the Keychain on every change — never written to UserDefaults.
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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.apiKey = KeychainStore.read(account: Keys.apiKey) ?? ""
        self.profileName = defaults.string(forKey: Keys.profile) ?? ""
        self.languageOverride = defaults.string(forKey: Keys.language) ?? ""
        self.styleExamples = defaults.string(forKey: Keys.style) ?? ""
        // Defaults to true on first launch (no stored value yet).
        self.tiktokAsDraft = defaults.object(forKey: Keys.tiktokDraft) as? Bool ?? true
        // Default to Gemma: it already ships and uses less memory.
        self.copywriterModel = defaults.string(forKey: Keys.copywriter)
            .flatMap(CopywriterModel.init) ?? .gemmaE4B
        // Default on — the user opted into the hook-overlay feature.
        self.burnHookOverlay = defaults.object(forKey: Keys.burnHook) as? Bool ?? true
    }

    /// True once the app has enough to publish.
    var isConfigured: Bool {
        !apiKey.trimmed.isEmpty && !profileName.trimmed.isEmpty
    }

    private func persistAPIKey() {
        let trimmed = apiKey.trimmed
        if trimmed.isEmpty {
            KeychainStore.delete(account: Keys.apiKey)
        } else {
            KeychainStore.save(trimmed, account: Keys.apiKey)
        }
    }

    private enum Keys {
        static let profile     = "shortcast.profileName"
        static let language    = "shortcast.languageOverride"
        static let style       = "shortcast.styleExamples"
        static let tiktokDraft = "shortcast.tiktokAsDraft"
        static let copywriter  = "shortcast.copywriterModel"
        static let burnHook    = "shortcast.burnHookOverlay"
        static let apiKey      = "upload-post-api-key"
    }
}
