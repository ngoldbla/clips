import SwiftUI
import UniformTypeIdentifiers

/// The idle state: a big drag-and-drop target for a short video.
struct DropZoneView: View {

    let isDropTargeted: Bool
    let onChooseFile: (URL) -> Void

    @Environment(WorkspaceModel.self) private var workspace
    @State private var showingImporter = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            dropArea

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
    }

    private var dropArea: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

            Text("Drop a short video here")
                .font(.title2.weight(.semibold))

            Text("Up to 60 seconds — a TikTok, Reel or Short")
                .font(.callout)
                .foregroundStyle(.secondary)

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
