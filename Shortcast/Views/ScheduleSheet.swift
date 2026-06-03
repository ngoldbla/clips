import SwiftUI

/// Schedules the approved shorts across the coming days — one every N days,
/// starting from a chosen date and time. Each clip is uploaded with a
/// `scheduled_date` so Upload-Post publishes it later automatically.
struct ScheduleSheet: View {

    @Environment(AppSettings.self) private var settings
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    @State private var startDate = ScheduleSheet.defaultStart
    @State private var intervalDays = 1
    /// Set once scheduling finishes — switches the sheet to the success view.
    @State private var scheduledCount: Int?
    @State private var failedCount = 0

    private static let calendarURL = URL(string: "https://app.upload-post.com/calendar")!

    private var plan: [(clip: ShortClip, date: Date)] {
        workspace.schedulePlan(start: startDate, intervalDays: intervalDays)
    }

    var body: some View {
        if let scheduledCount {
            successView(scheduled: scheduledCount)
        } else {
            formView
        }
    }

    // MARK: - Form

    private var formView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Schedule your shorts").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            Form {
                Section {
                    DatePicker("First short goes out",
                               selection: $startDate,
                               in: Date()...,
                               displayedComponents: [.date, .hourAndMinute])

                    Stepper(value: $intervalDays, in: 1...14) {
                        Text(intervalDays == 1
                             ? "One every day"
                             : "One every \(intervalDays) days")
                    }
                } header: {
                    Text("When")
                } footer: {
                    Text("\(plan.count) approved short\(plan.count == 1 ? "" : "s") will be queued. Times use this Mac's timezone.")
                }

                Section("Plan") {
                    if plan.isEmpty {
                        Text("No approved shorts to schedule yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(plan.enumerated()), id: \.element.clip.id) { index, item in
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.caption.weight(.bold))
                                    .frame(width: 20, height: 20)
                                    .background(.tint, in: Circle())
                                    .foregroundStyle(.white)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.clip.candidate.hook.isEmpty
                                         ? "Untitled moment" : item.clip.candidate.hook)
                                        .font(.callout).lineLimit(1)
                                    Text(Self.format(item.date))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button {
                    let start = startDate
                    let interval = intervalDays
                    let planned = plan.map(\.clip)
                    Task {
                        await workspace.scheduleAllApproved(
                            start: start, intervalDays: interval, settings: settings)
                        failedCount = planned.filter {
                            $0.scheduledDate == nil && $0.publishError != nil
                        }.count
                        scheduledCount = planned.filter { $0.scheduledDate != nil }.count
                    }
                } label: {
                    if workspace.isSchedulingAll {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Scheduling…")
                        }
                        .frame(minWidth: 180)
                    } else {
                        Label("Schedule \(plan.count) short\(plan.count == 1 ? "" : "s")",
                              systemImage: "calendar.badge.clock")
                            .frame(minWidth: 180)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(plan.isEmpty || workspace.isSchedulingAll)
            }
            .padding(16)
        }
        .frame(width: 460, height: 560)
    }

    // MARK: - Success

    private func successView(scheduled: Int) -> some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 6) {
                Text(scheduled == 0 ? "Nothing scheduled" : "Scheduled!")
                    .font(.title2.weight(.bold))
                Text(scheduled == 1
                     ? "1 short is queued and will publish automatically."
                     : "\(scheduled) shorts are queued and will publish automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if failedCount > 0 {
                    Label("\(failedCount) couldn't be scheduled — check those cards.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 30)

            Link(destination: Self.calendarURL) {
                Label("View in Upload-Post calendar", systemImage: "calendar")
                    .frame(minWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(16)
        }
        .frame(width: 460, height: 560)
    }

    // MARK: - Helpers

    /// Tomorrow at 10:00 local time.
    private static var defaultStart: Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f.string(from: date)
    }
}
