import SwiftUI

/// Results for the long-video flow: a grid of generated shorts you can scan at a
/// glance. Each tile previews one clip in a phone frame with quick actions
/// (play with sound, download, approve) and opens the full caption editor on tap.
struct ShortsResultsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(WorkspaceModel.self) private var workspace
    @State private var showingScheduler = false

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(workspace.clips) { clip in
                        ShortClipTile(clip: clip)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }

            Divider()
            footer
        }
        .sheet(isPresented: $showingScheduler) { ScheduleSheet() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.55)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 42, height: 42)
                Image(systemName: "scissors")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.job?.fileName ?? "Your shorts")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    statChip("\(workspace.clips.count) shorts", "rectangle.stack")
                    if let lang = workspace.clips.compactMap(\.detectedLanguage).first {
                        statChip(lang.uppercased(), "globe")
                    }
                    statChip("\(workspace.approvedReadyCount) approved", "checkmark.circle")
                }
            }

            Spacer()

            Button {
                workspace.startOver()
            } label: {
                Label("Start over", systemImage: "arrow.counterclockwise")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func statChip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            if settings.tiktokAsDraft {
                Label("TikTok uploads as a draft", systemImage: "tray.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if settings.isConfigured {
                Button {
                    showingScheduler = true
                } label: {
                    Label("Schedule…", systemImage: "calendar.badge.clock")
                        .frame(minWidth: 120)
                }
                .controlSize(.large)
                .disabled(workspace.approvedReadyCount == 0)

                Button {
                    Task { await workspace.publishAllApproved(settings: settings) }
                } label: {
                    if workspace.isPublishingAll {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Publishing…")
                        }
                        .frame(minWidth: 200)
                    } else {
                        Label("Publish now (\(workspace.approvedReadyCount))",
                              systemImage: "paperplane.fill")
                            .frame(minWidth: 200)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(workspace.isPublishingAll || workspace.approvedReadyCount == 0)
            } else {
                HStack(spacing: 10) {
                    Text("Connect your Upload-Post account to publish.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SettingsLink { Text("Open Settings") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
