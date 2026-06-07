import SwiftUI
import UniformTypeIdentifiers

/// Root view and state machine: model gate → drop → processing → results.
struct ContentView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager
    @Environment(WorkspaceModel.self) private var workspace

    @State private var isDropTargeted = false
    @State private var showingHistory = false

    var body: some View {
        ZStack {
            if modelManager.isLaunchComplete {
                workspaceContent
                    .transition(.opacity)
            } else {
                ModelDownloadView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.32), value: modelManager.isLaunchComplete)
        .animation(.smooth(duration: 0.32), value: workspace.phase)
        .frame(minWidth: 1000, minHeight: 720)
        .dropDestination(for: URL.self) { urls, _ in
            guard modelManager.isLaunchComplete else { return false }
            let files = urls.filter { $0.isFileURL }
            if !files.isEmpty {
                // Enqueue every dropped video — the queue drains them serially.
                workspace.enqueue(urls: files, modelManager: modelManager, settings: settings)
                return true
            }
            // A dragged web link → ingest if it's a YouTube URL and the feature's on.
            if settings.youTubeIngestEnabled,
               let link = urls.first(where: { YouTubeIngest.looksLikeYouTube($0.absoluteString) }) {
                workspace.enqueueYouTube(link: link.absoluteString, modelManager: modelManager, settings: settings)
                return true
            }
            return false
        } isTargeted: { isDropTargeted = $0 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    workspace.refreshLibrary()
                    showingHistory = true
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView()
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch workspace.phase {
        case .empty:
            DropZoneView(isDropTargeted: isDropTargeted, onChooseFile: startProcessing)
        case .processing:
            ProcessingView()
        case .results:
            ResultsView()
        case .transcribing, .findingMoments:
            ShortsProgressView()
        case .shortsResults:
            ShortsResultsView()
        }
    }

    private func startProcessing(_ url: URL) {
        Task {
            await workspace.process(url: url, modelManager: modelManager, settings: settings)
        }
    }
}
