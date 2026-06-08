import Foundation

/// One selectable Kokoro voice, with a human label and language group derived
/// from its id prefix (af_/am_ American, bf_/bm_ British, jf_/jm_ Japanese,
/// zf_/zm_ Chinese, …).
struct Voice: Identifiable, Sendable, Equatable {
    let id: String          // e.g. "af_heart"
    var displayName: String // e.g. "Heart (American ♀)"
    var group: String       // e.g. "American English"
}

/// Enumerates the voices actually present in the downloaded Kokoro bundle, so the
/// picker can never list a voice the bundle lacks. Falls back to the package
/// default (`af_heart`) when the bundle hasn't been downloaded yet.
///
/// `speech-swift`'s `KokoroTTSModel.fromPretrained()` downloads `voices/*.json`
/// into `~/Library/Caches/qwen3-speech/<model>/voices/` and loads every one into
/// its embedding table, so any id this finds on disk is safe to synthesize.
enum VoiceCatalog {

    static let defaultVoiceID = "af_heart"

    /// All installed voice ids found under the speech-swift cache, sorted by group
    /// then id. Empty array means "not downloaded yet" — callers should fall back
    /// to `defaultVoiceID`.
    static func installed() -> [Voice] {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else {
            return []
        }
        let root = caches.appendingPathComponent("qwen3-speech", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }

        var ids = Set<String>()
        for case let url as URL in enumerator
        where url.pathExtension == "json" && url.deletingLastPathComponent().lastPathComponent == "voices" {
            ids.insert(url.deletingPathExtension().lastPathComponent)
        }
        return ids.map(makeVoice).sorted { ($0.group, $0.id) < ($1.group, $1.id) }
    }

    /// A display Voice for any id, prefix-decoded (works even before download).
    static func makeVoice(_ id: String) -> Voice {
        let prefix = String(id.prefix(2))
        let (group, sex): (String, String)
        switch prefix {
        case "af": (group, sex) = ("American English", "♀")
        case "am": (group, sex) = ("American English", "♂")
        case "bf": (group, sex) = ("British English", "♀")
        case "bm": (group, sex) = ("British English", "♂")
        case "jf": (group, sex) = ("Japanese", "♀")
        case "jm": (group, sex) = ("Japanese", "♂")
        case "zf": (group, sex) = ("Chinese", "♀")
        case "zm": (group, sex) = ("Chinese", "♂")
        default:   (group, sex) = ("Other", "")
        }
        let name = id.split(separator: "_").dropFirst().joined(separator: " ").capitalized
        return Voice(id: id, displayName: "\(name.isEmpty ? id : name) (\(group) \(sex))".trimmingCharacters(in: .whitespaces),
                     group: group)
    }
}
