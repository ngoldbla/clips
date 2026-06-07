import SwiftUI

/// Shown while Gemma 4 watches and listens to the dropped video — the clip
/// itself plays in a phone frame with a pulsing "analyzing" ring.
struct ProcessingView: View {

    @Environment(WorkspaceModel.self) private var workspace
    @Environment(ModelManager.self) private var modelManager
    @State private var pulse = false

    /// While the copywriter loads lazily (16 GB doesn't preload it), reflect the
    /// download/load state; otherwise the model is running on the clip.
    private var headline: String {
        switch modelManager.phase {
        case .downloading: return "Downloading the captioning model…"
        case .loading:     return "Preparing the model for your Mac…"
        default:           return "Watching and listening to your video…"
        }
    }

    private var subline: String {
        switch modelManager.phase {
        case .downloading(let fraction, _):
            return "First run only — \(Int(fraction * 100))%. After this, Clipmunk never sends your videos anywhere."
        case .loading:
            return "First run only — optimizing for your Mac."
        default:
            return "Gemma 4 is running on your Mac. This usually takes 10–30 seconds."
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            if let url = workspace.job?.url {
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.black)
                    PhoneVideoPlayer(url: url)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(pulse ? 0.95 : 0.2),
                                      lineWidth: 3)
                }
                .frame(width: 236, height: 420)
                .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                           value: pulse)
                .onAppear { pulse = true }
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(headline)
                        .font(.title3.weight(.semibold))
                }

                if let job = workspace.job {
                    Text("\(job.fileName)  ·  \(job.durationLabel)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text(subline)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                if let job = workspace.job, job.exceedsRecommendedLength {
                    Text("This clip is over 60s — the model hears the first 30s of audio and samples frames across the whole video.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            }

            Spacer()
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
