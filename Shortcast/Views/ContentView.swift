import SwiftUI
import UniformTypeIdentifiers

/// Root view and state machine: model gate → drop → processing → results.
struct ContentView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager
    @Environment(WorkspaceModel.self) private var workspace

    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            if modelManager.isReady {
                workspaceContent
                    .transition(.opacity)
            } else {
                ModelDownloadView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.32), value: modelManager.isReady)
        .animation(.smooth(duration: 0.32), value: workspace.phase)
        .frame(minWidth: 1000, minHeight: 720)
        .dropDestination(for: URL.self) { urls, _ in
            guard modelManager.isReady,
                  !workspace.isBusy,
                  let url = urls.first(where: { $0.isFileURL })
            else { return false }
            startProcessing(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
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
