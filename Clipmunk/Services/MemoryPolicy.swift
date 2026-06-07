import Foundation
import MLX

/// Central memory policy for on-device model loading, tuned so Clipmunk runs
/// without swapping on a 16 GB Apple Silicon Mac while still using the stronger
/// models when there's headroom (24 GB+).
///
/// Why this exists: the heavy path is the "Director" LLM (Gemma 4 12B ≈ 13 GB
/// resident, Qwen 3.5 9B ≈ 6 GB) plus the optional E4B copywriter (~5 GB) and
/// WhisperKit (~2 GB CoreML). On 16 GB, loading the 12B — or keeping E4B resident
/// next to any Director, or Whisper next to the Director — overflows physical RAM
/// and macOS swaps, turning a 2-minute job into an hour. Every decision here keeps
/// at most one large model resident at a time and sizes the Director to the Mac.
enum MemoryPolicy {

    /// Physical RAM in whole GB (unified memory on Apple Silicon).
    static var systemRAMGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }

    /// 24 GB+ can hold two models at once (Director + copywriter) and the 12B
    /// Director comfortably. Below that we stay lean: a lighter Director,
    /// sequential loads, and models freed the moment they're no longer needed.
    static var canKeepBothResident: Bool { systemRAMGB >= 24 }

    /// True on memory-constrained Macs (≈16 GB) where RAM must be actively managed.
    static var isConstrained: Bool { systemRAMGB < 24 }

    /// Preload the multimodal copywriter (Gemma 4 E4B, ~5 GB) at launch only when
    /// there's room. On 16 GB it loads lazily the first time a flow actually needs
    /// it, so the default shorts+inline path never pays for a model it won't use.
    static var shouldPreloadCopywriter: Bool { canKeepBothResident }

    /// Free WhisperKit (~2 GB CoreML) after transcription, before the Director
    /// loads — on 16 GB the two shouldn't be resident together.
    static var shouldFreeWhisperAfterTranscribe: Bool { isConstrained }

    /// Configure MLX's Metal allocator for this Mac. Caps the reuse-buffer cache so
    /// freed weights/KV return to the OS instead of being hoarded, and sets a soft
    /// memory ceiling that makes MLX wait on in-flight work before growing — a
    /// guardrail against the system reaching for swap. Call once, at launch.
    static func configureMLX() {
        // Smaller cache → lower peak footprint at the cost of a little malloc
        // churn. On 16 GB we bias hard toward a low peak; roomy Macs keep more
        // cache for throughput.
        let cacheMB = isConstrained ? 256 : 1024
        MLX.Memory.cacheLimit = cacheMB * 1024 * 1024

        // Soft ceiling on constrained Macs: leave ~6 GB for the OS, WhisperKit
        // (CoreML) and AVFoundation export buffers, and to cap the transient spike
        // when the Director prefills a long transcript. Exceeding it makes MLX
        // malloc wait on scheduled tasks (freeing transient buffers) rather than
        // letting the footprint balloon — it never fails an allocation, just
        // throttles, so a long video stays within RAM instead of swapping.
        if isConstrained {
            let limitGB = max(8, systemRAMGB - 6)
            MLX.Memory.memoryLimit = limitGB * 1024 * 1024 * 1024
        }

        log("configured — RAM \(systemRAMGB)GB, constrained=\(isConstrained), "
            + "cache \(cacheMB)MB, memoryLimit \(isConstrained ? "\(max(8, systemRAMGB - 6))GB" : "default")")
    }

    /// Release all cached MLX buffers back to the OS. Cheap; call at stage
    /// boundaries (after Whisper, after the Director, after the pipeline).
    static func releaseCaches() {
        MLX.Memory.clearCache()
    }

    /// A one-line snapshot of MLX memory for stage timing logs.
    static func snapshot() -> String {
        let mb = { (bytes: Int) in bytes / (1024 * 1024) }
        return "mlx active=\(mb(MLX.Memory.activeMemory))MB "
            + "cache=\(mb(MLX.Memory.cacheMemory))MB peak=\(mb(MLX.Memory.peakMemory))MB"
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[clipmunk/memory] \(message)\n".utf8))
    }
}
