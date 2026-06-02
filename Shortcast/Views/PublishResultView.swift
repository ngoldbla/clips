import SwiftUI

/// Sheet summarising the outcome of a publish. Reusable for both the
/// single-video flow and per-clip shorts publishing — pass the report/error.
struct PublishResultView: View {

    let report: UploadPostClient.PublishReport?
    let error: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())

            if let error {
                Label(error, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let report {
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
        error != nil ? "Publish failed" : "Sent to Upload-Post"
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
