import SwiftUI

/// First-run (and reload) screen: downloads Gemma 4 and loads it into memory.
struct ModelDownloadView: View {

    @Environment(ModelManager.self) private var modelManager

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: "wand.and.stars")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)

            Text("Clipmunk")
                .font(.largeTitle.bold())

            Text("One short video becomes ready-to-post copy for TikTok, Instagram Reels and YouTube Shorts — generated entirely on your Mac.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)

            statusCard
                .frame(maxWidth: 460)

            if !modelManager.hasEnoughRAM {
                Label(
                    "This Mac has \(modelManager.systemRAMGB) GB of memory. Gemma 4 E4B works best with \(modelManager.recommendedRAMGB) GB or more — it may run slowly.",
                    systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            Spacer()

            Text("The model downloads once (~\(modelManager.estimatedDownloadGB) GB). After that, Clipmunk never sends your videos anywhere.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusCard: some View {
        switch modelManager.phase {
        case .idle:
            card { ProgressView("Preparing…") }
        case .downloading(let fraction, let detail):
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Downloading Gemma 4 E4B")
                        .font(.headline)
                    ProgressView(value: fraction)
                    Text(detail)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        case .loading:
            card { ProgressView("Loading the model into memory…") }
        case .ready:
            EmptyView()
        case .failed(let message):
            card {
                VStack(spacing: 12) {
                    Label("Couldn't load the model", systemImage: "xmark.octagon")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") {
                        modelManager.resetForRetry()
                        Task { await modelManager.prepareIfNeeded() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}
