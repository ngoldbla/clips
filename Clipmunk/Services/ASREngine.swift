import Foundation

/// An on-device speech-to-text engine. `TranscriptionService` owns one or more
/// and picks per job (Parakeet on constrained Macs / English; WhisperKit
/// otherwise and as a hard fallback). The public transcription surface
/// (`TranscriptionService.transcript(for:languageHint:)`) is unchanged — the
/// engine choice is entirely internal.
@MainActor
protocol ASREngine: AnyObject {
    /// Transcribes the audio at `audioURL` (an extracted `.m4a`). `languageHint`
    /// is a user override ("es", "Spanish") or empty for auto. `onPhase` reports
    /// progress so the service can surface download/transcribe state in the UI.
    func transcribe(
        audioURL: URL, languageHint: String,
        onPhase: @escaping @MainActor (TranscriptionService.Phase) -> Void
    ) async throws -> Transcript

    /// True when the engine currently holds a loaded model in memory.
    var isLoaded: Bool { get }

    /// Releases the in-memory model. Weights stay cached on disk.
    func unload()
}
