import SwiftUI

/// Shown while Gemma 4 watches and listens to the dropped video.
struct ProcessingView: View {

    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            ProgressView()
                .controlSize(.large)

            Text("Watching and listening to your video…")
                .font(.title3.weight(.semibold))

            if let job = workspace.job {
                Label("\(job.fileName)  ·  \(job.durationLabel)", systemImage: "film")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if job.exceedsRecommendedLength {
                    Text("This clip is longer than 60s — the model hears the first 30s of audio and samples frames across the whole video.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            }

            Text("Gemma 4 is running on your Mac. This usually takes 10–30 seconds.")
                .font(.callout)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
