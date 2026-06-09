import Foundation

/// Resolves the Hugging Face read token used to download **gated** model repos.
///
/// The mandatory Marlin-2B vision model (`junwatu/Marlin-2B-MLX-8bit`) is
/// `gated=auto` on Hugging Face, so an anonymous download 401s. The Director
/// (Gemma E2B) and the STT/TTS models are ungated and need no token.
///
/// Resolution order (first non-empty wins):
///   1. `HF_TOKEN` / `HUGGING_FACE_HUB_TOKEN` / `HUGGINGFACE_TOKEN` env var —
///      lets a developer or a CI probe override without rebuilding.
///   2. The token baked into the app's Info.plist (`HFDownloadToken`) at build
///      time. Release builds get it injected from the `HF_DOWNLOAD_TOKEN` CI
///      secret; it is NEVER committed to source (the repo is public, and HF
///      auto-revokes leaked tokens).
///   3. `~/.cache/huggingface/token` — a local `huggingface-cli login`, so a
///      developer's own login makes local (unsigned) builds work too.
///
/// Returns `nil` when nothing is configured; ungated repos still download fine.
enum HFToken {

    static func resolve() -> String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACE_TOKEN"] {
            if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return v
            }
        }

        if let baked = Bundle.main.object(forInfoDictionaryKey: "HFDownloadToken") as? String {
            let v = baked.trimmingCharacters(in: .whitespacesAndNewlines)
            // Guard against an unsubstituted build variable on dev builds.
            if !v.isEmpty, v != "$(HF_DOWNLOAD_TOKEN)" { return v }
        }

        let cliToken = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/token")
        if let contents = try? String(contentsOf: cliToken, encoding: .utf8) {
            let v = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }

        return nil
    }
}
