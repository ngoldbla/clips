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

            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    ForEach($workspace.variants) { $variant in
                        PostCardView(variant: $variant)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .sheet(isPresented: publishResultPresented) {
            PublishResultView()
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
                    Text("Three drafts ready — edit anything before publishing")
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

/// Sheet summarising the outcome of a publish.
private struct PublishResultView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())

            if let error = workspace.publishError {
                Label(error, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let report = workspace.publishReport {
                ForEach(SocialPlatform.allCases) { platform in
                    if let outcome = report.outcomes[platform] {
                        outcomeRow(platform, outcome)
                    }
                }
                if let requestID = report.requestID {
                    Text("Request ID: \(requestID)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var title: String {
        if workspace.publishError != nil { return "Publish failed" }
        return "Sent to Upload-Post"
    }

    @ViewBuilder
    private func outcomeRow(_ platform: SocialPlatform, _ outcome: UploadPostClient.PlatformOutcome) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            switch outcome {
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .submitted:
                Image(systemName: "clock.fill").foregroundStyle(.orange)
            case .failure:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(platform.displayName).fontWeight(.medium)
                Text(detail(for: outcome))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detail(for outcome: UploadPostClient.PlatformOutcome) -> String {
        switch outcome {
        case .success(let url):       url ?? "Published."
        case .submitted:              "Accepted — finishing on Upload-Post."
        case .failure(let message):   message
        }
    }
}
