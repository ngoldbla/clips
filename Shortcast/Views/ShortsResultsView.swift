import SwiftUI

/// Results for the long-video flow: a scrollable list of generated shorts, each
/// reviewable and publishable on its own, plus a "Publish all approved" action.
struct ShortsResultsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(workspace.clips) { clip in
                        ShortClipCard(clip: clip)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }

            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "scissors")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.job?.fileName ?? "Your video")
                    .font(.headline)
                    .lineLimit(1)
                Text("\(workspace.clips.count) shorts  ·  tap any line on a preview to edit it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                workspace.startOver()
            } label: {
                Label("Start over", systemImage: "arrow.counterclockwise")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if settings.tiktokAsDraft {
                Label("TikTok uploads as a draft", systemImage: "tray.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if settings.isConfigured {
                Button {
                    Task { await workspace.publishAllApproved(settings: settings) }
                } label: {
                    if workspace.isPublishingAll {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Publishing…")
                        }
                        .frame(minWidth: 200)
                    } else {
                        Label("Publish all approved (\(workspace.approvedReadyCount))",
                              systemImage: "paperplane.fill")
                            .frame(minWidth: 200)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(workspace.isPublishingAll || workspace.approvedReadyCount == 0)
            } else {
                HStack(spacing: 10) {
                    Text("Connect your Upload-Post account to publish.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SettingsLink { Text("Open Settings") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
