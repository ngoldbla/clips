import SwiftUI

/// The single configuration screen (⌘,): Upload-Post account, caption style,
/// publishing options, and model status.
struct SettingsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager

    private enum ConnectionState: Equatable {
        case idle, checking, ok, failed(String)
    }
    @State private var connection: ConnectionState = .idle

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Upload-Post account") {
                SecureField("API key", text: $settings.apiKey)
                TextField("Profile name", text: $settings.profileName)

                Text("Create an API key and a profile in the Upload-Post dashboard. The profile name is the one from **Manage Users** — not your social handle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Test connection", action: testConnection)
                        .disabled(settings.apiKey.trimmed.isEmpty || connection == .checking)
                    connectionStatus
                    Spacer()
                    Link("Connect accounts ↗", destination: URL(string: "https://app.upload-post.com")!)
                }
            }

            Section("Captions") {
                TextField(
                    "Language",
                    text: $settings.languageOverride,
                    prompt: Text("Auto-detect from the video"))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Your style examples")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $settings.styleExamples)
                        .font(.body)
                        .frame(height: 110)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                    Text("Optional. Paste a few captions you like — the model will match your voice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Publishing") {
                Toggle("Upload TikTok as a draft", isOn: $settings.tiktokAsDraft)
                Text("Drafts land in the TikTok inbox so you can finish editing in the app before posting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                LabeledContent("Model", value: "Gemma 4 E4B · 4-bit")
                LabeledContent("This Mac's memory", value: "\(modelManager.systemRAMGB) GB")
                LabeledContent("Status", value: modelStatus)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 600)
    }

    // MARK: - Connection test

    @ViewBuilder
    private var connectionStatus: some View {
        switch connection {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .ok:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
        }
    }

    private func testConnection() {
        connection = .checking
        let client = UploadPostClient(
            apiKey: settings.apiKey,
            profileName: settings.profileName)
        Task {
            do {
                try await client.checkConnection()
                connection = .ok
            } catch {
                connection = .failed(error.localizedDescription)
            }
        }
    }

    private var modelStatus: String {
        switch modelManager.phase {
        case .idle:                          "Not loaded"
        case .downloading(let fraction, _):  "Downloading \(Int(fraction * 100))%"
        case .loading:                       "Loading…"
        case .ready:                         "Ready"
        case .failed:                        "Failed to load"
        }
    }
}
