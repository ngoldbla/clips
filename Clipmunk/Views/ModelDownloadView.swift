import SwiftUI

/// Brief launch splash. Models are no longer downloaded at launch — the Director
/// (Gemma 4 E2B) and WhisperKit load lazily on the first job — so this shows only
/// for the instant before the workspace opens.
struct ModelDownloadView: View {

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: "wand.and.stars")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)

            Text("Clipmunk")
                .font(.largeTitle.bold())

            Text("One long video becomes ready-to-post shorts for TikTok, Instagram Reels and YouTube Shorts — generated entirely on your Mac.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)

            ProgressView()
                .controlSize(.small)
                .padding(.top, 8)

            Spacer()

            Text("Models download once on first use, then everything runs offline.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
