import SwiftUI

/// One generated short: its hook + rationale, an Approve toggle, the three
/// editable platform previews of the cut clip, and a per-clip Publish action.
struct ShortClipCard: View {

    @Bindable var clip: ShortClip
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch clip.stage {
            case .pending, .cutting, .captioning:
                working
            case .failed(let message):
                failed(message)
            case .ready:
                if clip.isLandscape { reframeEditor }
                captionEditor
                overlayEditor
                previews
                footer
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
        .opacity(clip.isApproved ? 1 : 0.55)
        .sheet(isPresented: publishResultPresented) {
            PublishResultView(report: clip.publishReport, error: clip.publishError)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.candidate.hook.isEmpty ? "Untitled moment" : clip.candidate.hook)
                    .font(.headline)
                HStack(spacing: 6) {
                    Label(clip.candidate.rangeLabel, systemImage: "scissors")
                    Text("·  \(Int(clip.candidate.duration.rounded()))s")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !clip.candidate.why.isEmpty {
                    Text(clip.candidate.why)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle("Approve", isOn: $clip.isApproved)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    // MARK: - States

    private var working: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(clip.stage == .cutting ? "Cutting the clip…" : "Writing captions…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    private func failed(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    private var reframeEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $clip.reframeEnabled) {
                Label("Convert to vertical (9:16)", systemImage: "aspectratio")
                    .font(.callout)
            }
            .toggleStyle(.switch)

            if clip.reframeEnabled {
                Text("Tracks the speaker and reframes this horizontal clip for TikTok/Reels/Shorts when you publish.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var captionEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $clip.captionsEnabled) {
                Label("Animated word captions", systemImage: "captions.bubble")
                    .font(.callout)
            }
            .toggleStyle(.switch)

            if clip.captionsEnabled {
                if clip.captionScript.isEmpty {
                    Text("No spoken words detected in this clip's range — nothing to caption.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Picker("Style", selection: captionStyleBinding) {
                        ForEach(CaptionStyle.presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Word-by-word captions, burned in when you publish or download. Preview them in “Play with sound”.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var captionStyleBinding: Binding<String> {
        Binding(
            get: { clip.captionStyle.id },
            set: { clip.captionStyle = CaptionStyle.preset(id: $0) })
    }

    private var overlayEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $clip.overlayEnabled) {
                Label("Text hook over the video (first 3s)", systemImage: "textformat")
                    .font(.callout)
            }
            .toggleStyle(.switch)

            if clip.overlayEnabled {
                TextField("On-screen hook", text: $clip.overlayText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...2)
                Text("Burned into the video when you publish.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var previews: some View {
        if let videoURL = clip.clipJob?.url {
            HStack(alignment: .top, spacing: 16) {
                ForEach($clip.variants) { $variant in
                    PostPreviewCard(
                        variant: $variant,
                        videoURL: videoURL,
                        overlayHook: clip.overlayEnabled ? clip.overlayText : nil)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Footer (per-clip publish)

    @ViewBuilder
    private var footer: some View {
        if settings.isConfigured {
            HStack {
                Spacer()
                Button {
                    Task { await clip.publish(settings: settings) }
                } label: {
                    if clip.isPublishing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Publishing…")
                        }
                        .frame(minWidth: 150)
                    } else {
                        Label("Publish this short", systemImage: "paperplane.fill")
                            .frame(minWidth: 150)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(clip.isPublishing || clip.variants.isEmpty)
            }
        }
    }

    private var publishResultPresented: Binding<Bool> {
        Binding(
            get: { clip.publishReport != nil || clip.publishError != nil },
            set: { if !$0 { clip.dismissPublishResult() } })
    }
}
