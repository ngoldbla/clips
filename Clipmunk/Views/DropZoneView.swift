import SwiftUI
import UniformTypeIdentifiers

/// The idle state: a big drag-and-drop target for a short video.
struct DropZoneView: View {

    let isDropTargeted: Bool
    let onChooseFile: (URL) -> Void

    @Environment(WorkspaceModel.self) private var workspace
    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager
    @State private var showingImporter = false
    @State private var urlText = ""
    @State private var installingYtDlp = false
    @State private var showInstallPrompt = false

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 18) {
            Spacer()

            Picker("Mode", selection: $workspace.inputMode) {
                ForEach(WorkspaceModel.InputMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)

            dropArea

            if settings.youTubeIngestEnabled && workspace.inputMode == .shorts {
                youTubeField
            }

            if let error = workspace.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            Spacer()

            Text("Everything runs on your Mac. Your video is never uploaded until you press Publish.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        ) { result in
            if case .success(let url) = result { onChooseFile(url) }
        }
        .confirmationDialog("Download yt-dlp?", isPresented: $showInstallPrompt) {
            Button("Download yt-dlp") { installAndEnqueue() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("YouTube videos are downloaded with yt-dlp, a small open-source tool. Clipmunk fetches the official build (checksum-verified) into Application Support — it's never bundled, and you can delete it any time.")
        }
    }

    // MARK: - YouTube link (opt-in)

    private var youTubeField: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField("Paste a YouTube link", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitURL)
                if installingYtDlp {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Make shorts", action: submitURL)
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Text("Fetches captions over the network and downloads the video with opt-in yt-dlp — the one step that leaves your Mac.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 460)
    }

    private func submitURL() {
        let link = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        guard YouTubeIngest.looksLikeYouTube(link) else {
            workspace.errorMessage = "That doesn't look like a YouTube link."
            return
        }
        if YtDlpManager.isAvailable {
            workspace.enqueueYouTube(link: link, modelManager: modelManager, settings: settings)
            urlText = ""
        } else {
            showInstallPrompt = true
        }
    }

    private func installAndEnqueue() {
        let link = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        installingYtDlp = true
        Task {
            do {
                try await YtDlpManager.install()
                workspace.enqueueYouTube(link: link, modelManager: modelManager, settings: settings)
                urlText = ""
            } catch {
                workspace.errorMessage = "Couldn't install yt-dlp: \(error.localizedDescription)"
            }
            installingYtDlp = false
        }
    }

    private var dropArea: some View {
        VStack(spacing: 14) {
            Image(systemName: workspace.inputMode.symbol)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

            Text(workspace.inputMode.dropTitle)
                .font(.title2.weight(.semibold))

            Text(workspace.inputMode.dropSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Choose video…") { showingImporter = true }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: 560, minHeight: 320)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(isDropTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.08))
                                     : AnyShapeStyle(Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
        )
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }
}
