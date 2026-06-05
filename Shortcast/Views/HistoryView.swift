import SwiftUI

/// Browse and re-open finished jobs saved to the on-device library. Re-opening
/// repopulates the results grid so a past batch can be re-previewed,
/// re-downloaded, or re-published.
struct HistoryView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()

            if workspace.library.isEmpty {
                ContentUnavailableView(
                    "No saved jobs yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Finished shorts are saved here automatically — fully on your Mac."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(workspace.library) { job in
                    row(job)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 580, height: 540)
    }

    private func row(_ job: StoredJob) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "scissors")
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.sourceFileName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(job.clips.count) shorts")
                    Text("·").foregroundStyle(.tertiary)
                    Text(job.createdAt, format: .dateTime.month().day().hour().minute())
                    if let lang = job.language, !lang.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(lang.uppercased())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open") {
                workspace.reopen(job)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button(role: .destructive) {
                workspace.deleteLibraryJob(job.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this saved job")
        }
        .padding(.vertical, 4)
    }
}
