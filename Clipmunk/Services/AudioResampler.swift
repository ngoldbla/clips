import AVFoundation
import Foundation

/// Converts any audio/video file's audio track into the exact format Parakeet
/// (and WhisperKit's array API) want: 16 kHz, mono, 32-bit float PCM as `[Float]`.
///
/// Source audio off an `AVAsset` is usually 44.1/48 kHz stereo, so a single
/// `AVAudioConverter` pass does both the sample-rate conversion AND the
/// stereo→mono downmix. Pure AVFoundation — no model dependency — so it can be
/// validated headlessly without loading any ASR model.
enum AudioResampler {

    enum ResampleError: LocalizedError {
        case noAudioTrack
        case converterUnavailable
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:       return "That file has no audio track to resample."
            case .converterUnavailable: return "Couldn't create the 16 kHz audio converter."
            case .readFailed(let d):  return "Couldn't read audio for resampling: \(d)"
            }
        }
    }

    /// Decodes `url`'s audio to 16 kHz mono Float32 PCM samples.
    static func pcm16kMono(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw ResampleError.noAudioTrack }
        let inFormat = file.processingFormat
        guard inFormat.channelCount > 0 else { throw ResampleError.noAudioTrack }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000,
            channels: 1, interleaved: false)
        else { throw ResampleError.converterUnavailable }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw ResampleError.converterUnavailable
        }

        let readChunk: AVAudioFrameCount = 16384
        guard let inBuffer = AVAudioPCMBuffer(
            pcmFormat: inFormat, frameCapacity: readChunk) else {
            throw ResampleError.converterUnavailable
        }

        var out: [Float] = []
        var reachedEOF = false
        var readError: Error?

        while !reachedEOF {
            let outCapacity = AVAudioFrameCount(
                Double(readChunk) * (16000.0 / inFormat.sampleRate) + 1024)
            guard let outBuffer = AVAudioPCMBuffer(
                pcmFormat: outFormat, frameCapacity: outCapacity) else {
                throw ResampleError.converterUnavailable
            }

            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                inBuffer.frameLength = 0
                do {
                    try file.read(into: inBuffer, frameCount: readChunk)
                } catch {
                    // AVAudioFile.read throws Foundation._GenericObjCError(code: 0)
                    // (nilError) as its normal EOF signal on some macOS versions.
                    // Only record non-EOF throws as real errors.
                    let nsErr = error as NSError
                    let isEOF = (nsErr.domain == "Foundation._GenericObjCError" && nsErr.code == 0)
                        || inBuffer.frameLength > 0
                    if !isEOF { readError = error }
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }

            if let conversionError { throw ResampleError.readFailed(conversionError.localizedDescription) }
            if let readError { throw ResampleError.readFailed(readError.localizedDescription) }

            if let channel = outBuffer.floatChannelData, outBuffer.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(
                    start: channel[0], count: Int(outBuffer.frameLength)))
            }

            if status == .endOfStream || status == .error { reachedEOF = true }
        }

        return out
    }
}
