import Foundation
import Observation

/// User configuration: Upload-Post credentials and content-style preferences.
///
/// The API key is persisted in the macOS Keychain; everything else lives in
/// `UserDefaults`. Held as an `@Observable` so SwiftUI views update on change.
@MainActor
@Observable
final class AppSettings {

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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.apiKey = KeychainStore.read(account: Keys.apiKey) ?? ""
        self.profileName = defaults.string(forKey: Keys.profile) ?? ""
        self.languageOverride = defaults.string(forKey: Keys.language) ?? ""
        self.styleExamples = defaults.string(forKey: Keys.style) ?? ""
        // Defaults to true on first launch (no stored value yet).
        self.tiktokAsDraft = defaults.object(forKey: Keys.tiktokDraft) as? Bool ?? true
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
        static let apiKey      = "upload-post-api-key"
    }
}
