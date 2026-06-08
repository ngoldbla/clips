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
                Picker("Caption language", selection: $settings.languageOverride) {
                    Text("English").tag("English")
                    Text("Spanish").tag("Spanish")
                    Text("French").tag("French")
                    Text("German").tag("German")
                    Text("Portuguese").tag("Portuguese")
                    Text("Italian").tag("Italian")
                    Text("Match the video's language").tag("")
                }
                Text("Captions are written in this language no matter what's spoken in the video. Defaults to English; pick \u{201C}Match the video\u{2019}s language\u{201D} to keep the spoken language instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

            Section("How a long video becomes shorts") {
                pipelineRole(
                    step: "1", icon: "waveform",
                    title: "Transcribe",
                    model: ModelCatalog.transcription.displayName,
                    detail: "Turns the audio into text. Runs only when the video has no .srt/.vtt next to it.",
                    status: nil)
                pipelineRole(
                    step: "2", icon: "wand.and.stars",
                    title: "Find the viral moments",
                    model: ChatModelProfile.director.displayName,
                    detail: "Reads the whole transcript and picks the best clips.",
                    status: directorStatus)
                pipelineRole(
                    step: "3", icon: "text.bubble",
                    title: "Write the captions",
                    model: ChatModelProfile.director.displayName,
                    detail: "The same model writes all three platforms' captions in the same pass.",
                    status: directorStatus)
            }

            Section("Animated captions") {
                Toggle("Burn animated word captions into each short", isOn: $settings.burnCaptions)
                if settings.burnCaptions {
                    Picker("Style", selection: $settings.captionStyleID) {
                        ForEach(CaptionStyle.presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                }
                Text("Word-by-word captions that highlight each word as it's spoken — the defining short-form look. The default for new shorts; you can flip it or change the style per clip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text hook overlay") {
                Toggle("Burn an AI text hook into each short", isOn: $settings.burnHookOverlay)
                Text("Shows a short hook over the top of each clip for the first few seconds. The default for new shorts — you can flip it per clip. The text is rendered into the video when you publish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Vertical reframing") {
                Toggle("Auto-convert horizontal clips to vertical 9:16", isOn: $settings.reframeToVertical)
                Text("Tracks the speaker with on-device Vision and reframes 16:9 → 9:16, falling back to a blurred background when there's no clear face. The default for new horizontal clips — you can flip it per clip. Applied when you publish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("YouTube links (opt-in)") {
                Toggle("Allow pasting a YouTube link", isOn: $settings.youTubeIngestEnabled)
                Text("Adds a link field on the drop screen. Clipmunk fetches the video's captions over the network (skipping Whisper when they exist) and downloads the video with yt-dlp — an opt-in, checksum-verified tool that's never bundled. This is the only feature that sends traffic off your Mac during processing, so it's off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.youTubeIngestEnabled {
                    LabeledContent("yt-dlp") {
                        Text(YtDlpManager.isAvailable ? "Installed" : "Installs on first use")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Vision-aware moment-finding (opt-in)") {
                Toggle("Let the model watch the video before picking moments", isOn: $settings.visionAwareMomentFinding)
                Text("Before the Director chooses clips, the on-device Marlin-2B video model watches the footage and hands it a timestamped \u{201C}what's on screen, when\u{201D} track — B-roll, on-screen text, scene changes the transcript can't reveal. Improves picks for visually rich videos, but adds a vision pass (extra time and a ~2.5 GB model download on first use). Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("This Mac") {
                LabeledContent("Memory", value: "\(modelManager.systemRAMGB) GB")
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

    @ViewBuilder
    private func pipelineRole(step: String, icon: String, title: String,
                             model: String, detail: String, status: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(step). \(title)").font(.callout.weight(.semibold))
                    Spacer()
                    Text(model).font(.callout).foregroundStyle(.secondary)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let status {
                    Text(status).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var directorStatus: String {
        switch modelManager.momentFinder.phase {
        case .idle:                        "Loads on first long video"
        case .downloading(let fraction):   "Downloading \(Int(fraction * 100))%"
        case .loading:                     "Loading…"
        case .ready:                       "Ready"
        case .failed:                      "Failed to load"
        }
    }
}
