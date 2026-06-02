import SwiftUI

/// Full-screen progress for the long-video → shorts pipeline: transcribing,
/// then finding moments. Once moments are found we switch to the results grid
/// and clips fill in per-card, so this view only covers the first two stages.
struct ShortsProgressView: View {

    @Environment(ModelManager.self) private var modelManager
    @Environment(WorkspaceModel.self) private var workspace
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            if let url = workspace.job?.url {
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.black)
                    PhoneVideoPlayer(url: url)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(pulse ? 0.95 : 0.2), lineWidth: 3)
                }
                .frame(width: 236, height: 420)
                .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(headline).font(.title3.weight(.semibold))
                }

                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }

                if let job = workspace.job {
                    Text("\(job.fileName)  ·  \(job.durationLabel)")
                        .font(.footnote).foregroundStyle(.tertiary)
                }
            }

            Button(role: .cancel) {
                workspace.cancelPipeline()
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .padding(.top, 4)

            Spacer()
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headline: String {
        switch workspace.phase {
        case .transcribing:
            if case .downloadingModel = workspace.transcription.phase {
                return "Downloading the transcription model…"
            }
            return "Transcribing your video…"
        case .findingMoments:
            return "Finding the best moments…"
        default:
            return "Working…"
        }
    }

    private var detail: String? {
        switch workspace.phase {
        case .transcribing:
            switch workspace.transcription.phase {
            case .downloadingModel(let f): return "First run only — \(Int(f * 100))%"
            default:                       return "Reading the whole timeline."
            }
        case .findingMoments:
            return "Qwen 3.5 9B is scanning the transcript — this can take a few minutes."
        default:
            return nil
        }
    }
}
