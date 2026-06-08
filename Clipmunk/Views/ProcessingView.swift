import SwiftUI

/// Shown while a dropped short is transcribed and the Director (Gemma 4 E2B)
/// writes its captions — the clip plays in a phone frame with a pulsing ring.
struct ProcessingView: View {

    @Environment(WorkspaceModel.self) private var workspace
    @Environment(ModelManager.self) private var modelManager
    @State private var pulse = false

    /// Reflects the two stages: transcribe the clip, then write the captions.
    private var headline: String {
        switch workspace.transcription.phase {
        case .downloadingModel: return "Downloading the transcription model…"
        case .preparingModel:   return "Preparing the transcription model…"
        case .transcribing:     return "Transcribing your video…"
        case .idle, .ready, .failed:
            switch modelManager.momentFinder.phase {
            case .downloading: return "Downloading the captioning model…"
            case .loading:     return "Preparing the model for your Mac…"
            default:           return "Writing your captions…"
            }
        }
    }

    private var subline: String {
        switch workspace.transcription.phase {
        case .downloadingModel(let f):
            return "First run only — \(Int(f * 100))%. After this, Clipmunk never sends your videos anywhere."
        case .preparingModel:
            return "First run only — optimizing transcription for your Mac."
        case .transcribing:
            return "Reading what's said in your clip."
        case .idle, .ready, .failed:
            switch modelManager.momentFinder.phase {
            case .downloading(let f):
                return "First run only — downloading the model (\(Int(f * 100))%)."
            case .loading:
                return "First run only — optimizing for your Mac."
            default:
                return "Gemma 4 E2B is running on your Mac. This usually takes a few seconds."
            }
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
            }

            Spacer()
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
