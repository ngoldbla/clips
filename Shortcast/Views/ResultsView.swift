import SwiftUI

/// The three editable cards plus the Publish action.
struct ResultsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            header
            Divider()

            if let videoURL = workspace.job?.url {
                ScrollView {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach($workspace.variants) { $variant in
                            PostPreviewCard(variant: $variant, videoURL: videoURL)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                }
            }

            Divider()
            footer
        }
        .sheet(isPresented: publishResultPresented) {
            PublishResultView(report: workspace.publishReport, error: workspace.publishError)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.job?.fileName ?? "Your video")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("Tap any line on a preview to edit it")
                    if let language = workspace.detectedLanguage, !language.isEmpty {
                        Text("·  \(language.uppercased())")
                    }
                }
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

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            if settings.tiktokAsDraft {
                Label("TikTok will be uploaded as a draft", systemImage: "tray.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if settings.isConfigured {
                Button {
                    Task { await workspace.publish(settings: settings) }
                } label: {
                    if workspace.isPublishing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Publishing…")
                        }
                        .frame(minWidth: 170)
                    } else {
                        Label("Publish to all three", systemImage: "paperplane.fill")
                            .frame(minWidth: 170)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(workspace.isPublishing || workspace.variants.isEmpty)
            } else {
                HStack(spacing: 10) {
                    Text("Connect your Upload-Post account to publish.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SettingsLink {
                        Text("Open Settings")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var publishResultPresented: Binding<Bool> {
        Binding(
            get: { workspace.publishReport != nil || workspace.publishError != nil },
            set: { if !$0 { workspace.dismissPublishResult() } })
    }
}
