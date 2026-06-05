import AVFoundation
import Accelerate
import Foundation

/// Reads a clip's audio and produces a per-time **speech-activity envelope** from
/// short-window RMS energy and a silence gate. `VerticalReframer` uses it to know
/// *who is talking* when picking which face to follow.
///
/// Fully on-device and native (Accelerate `vDSP`), `nonisolated`, and only ever
/// returns `Sendable` value types across isolation — the non-`Sendable`
/// `AVAudioFile`/`AVAudioPCMBuffer` stay inside the function, mirroring
/// `VerticalReframer.sampleFaces`. Ports the kit's audio-energy idea
/// (`audio_analysis.py`'s ~−40 dB silence threshold) natively.
enum AudioActivityAnalyzer {

    /// One sampled window: `time` (seconds from clip start) and a `speaking`
    /// probability in 0…1 (0 = silence, 1 = clear speech).
    struct Activity: Sendable, Equatable {
        let time: Double
        let speaking: Double
    }

    /// dB window mapped to 0…1 speech probability. Below the floor → silence;
    /// above the ceiling → confident speech.
    private static let silenceFloorDB: Float = -45
    private static let speechCeilDB: Float = -15

    /// Samples the clip's audio every `cadence` seconds (match the face-sampling
    /// cadence) and returns a speech-activity envelope. Returns `[]` when the clip
    /// has no audio, so single-/no-audio clips fall back to the old behaviour.
    nonisolated static func envelope(clipURL: URL, cadence: Double = 0.5) async -> [Activity] {
        guard let audioURL = try? await MediaExtractor.extractAudio(from: clipURL, maxSeconds: nil),
              let file = try? AVAudioFile(forReading: audioURL)
        else { return [] }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(file.length)
        guard sampleRate > 0, frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil,
              let channelData = buffer.floatChannelData
        else { return [] }

        let n = Int(buffer.frameLength)
        guard n > 0 else { return [] }
        let samples = channelData[0]               // first channel is plenty for VAD
        let windowFrames = max(1, Int(cadence * sampleRate))

        var out: [Activity] = []
        var i = 0
        while i < n {
            let count = min(windowFrames, n - i)
            var rms: Float = 0
            vDSP_rmsqv(samples + i, 1, &rms, vDSP_Length(count))
            let db = 20 * log10(max(rms, 1e-7))
            let speaking = Double(min(1, max(0, (db - silenceFloorDB) / (speechCeilDB - silenceFloorDB))))
            out.append(Activity(time: Double(i) / sampleRate, speaking: speaking))
            i += windowFrames
        }
        return out
    }

    /// The speaking probability at `time`, read from the nearest sampled window
    /// (0 when the envelope is empty — i.e. no audio).
    static func speaking(at time: Double, in envelope: [Activity]) -> Double {
        guard !envelope.isEmpty else { return 0 }
        // Envelope is evenly spaced and sorted; nearest by absolute time.
        var best = envelope[0]
        for a in envelope where abs(a.time - time) < abs(best.time - time) { best = a }
        return best.speaking
    }
}
