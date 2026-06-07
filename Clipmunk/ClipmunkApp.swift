import SwiftUI

@main
struct ClipmunkApp: App {

    @State private var settings = AppSettings()
    @State private var modelManager = ModelManager()
    @State private var workspace = WorkspaceModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(modelManager)
                .environment(workspace)
                .task {
                    // Size MLX's Metal allocator to this Mac before anything loads.
                    MemoryPolicy.configureMLX()
                    // Ask once for permission to notify when long jobs finish.
                    workspace.requestNotificationAuthorization()
                    // Decide what to preload: on 24 GB+ this brings up the
                    // copywriter now; on 16 GB it opens the workspace immediately
                    // and models load lazily per flow.
                    await modelManager.completeLaunch()
                    autorunIfRequested()
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {}  // single-window app
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(modelManager)
        }
    }

    /// Debug-only test seam: when `CLIPMUNK_AUTORUN_VIDEO` points at a video file,
    /// enqueue it for the shorts pipeline at launch — no UI interaction needed. Used
    /// to drive deterministic end-to-end performance/memory measurements. Compiled
    /// out of Release; a no-op unless the env var is set.
    private func autorunIfRequested() {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["CLIPMUNK_AUTORUN_VIDEO"],
              !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        workspace.inputMode = .shorts
        workspace.enqueue(urls: [url], modelManager: modelManager, settings: settings)
        #endif
    }
}
