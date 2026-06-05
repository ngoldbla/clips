import SwiftUI

@main
struct ShortcastApp: App {

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
                    // Ask once for permission to notify when long jobs finish.
                    workspace.requestNotificationAuthorization()
                    // Kick off the first-run download / model load.
                    await modelManager.prepareIfNeeded()
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
}
