import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers

/// A compact card in the shorts grid: a phone-style preview of one cut clip with
/// quick actions (play with sound, download, approve) and a tap target to open
/// the full caption editor. Designed so the whole batch is scannable at a glance.
struct ShortClipTile: View {

    @Bindable var clip: ShortClip
    @Environment(AppSettings.self) private var settings

    @State private var showEditor = false
    @State private var showPlayer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            phoneArea
            footer
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary))
        .opacity(clip.isApproved ? 1 : 0.5)
        .sheet(isPresented: $showEditor) { ClipEditorSheet(clip: clip) }
        .sheet(isPresented: $showPlayer) {
            if let url = clip.clipJob?.url {
                ClipPlayerSheet(url: url,
                                reframe: clip.reframeEnabled && clip.isLandscape,
                                title: clip.candidate.hook)
            }
        }
    }

    // MARK: - Phone preview + overlays

    @ViewBuilder
    private var phoneArea: some View {
        ZStack {
            switch clip.stage {
            case .ready:
                if let url = clip.clipJob?.url {
                    MiniPhone(url: url,
                              overlayHook: clip.overlayEnabled ? clip.overlayText : nil)
                        .contentShape(Rectangle())
                        .onTapGesture { showEditor = true }
                    overlays
                }
            case .failed(let message):
                placeholder { Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center) }
            default:
                placeholder {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(clip.stage == .cutting ? "Cutting…" : "Writing captions…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.85))
            content().padding(10)
        }
    }

    private var overlays: some View {
        VStack {
            HStack(alignment: .top) {
                // Duration chip.
                Text("\(Int(clip.candidate.duration.rounded()))s")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                if clip.isRendered {
                    Image(systemName: "aspectratio")
                        .font(.caption2.weight(.bold))
                        .padding(5)
                        .background(.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                }
                Spacer()
                // Approve toggle.
                Button {
                    clip.isApproved.toggle()
                } label: {
                    Image(systemName: clip.isApproved ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, clip.isApproved ? Color.accentColor : .black.opacity(0.4))
                        .background(Circle().fill(.black.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .help(clip.isApproved ? "Approved — included in Publish all" : "Not approved")
            }
            Spacer()
            // Action bar.
            HStack(spacing: 10) {
                tileButton("play.fill", "Play with sound") { showPlayer = true }
                tileButton("square.and.pencil", "Edit captions") { showEditor = true }
                if clip.isExporting {
                    ProgressView().controlSize(.small).frame(width: 30, height: 30)
                } else {
                    tileButton("arrow.down.circle", "Download") { runSavePanel() }
                }
            }
            .padding(6)
            .background(.black.opacity(0.4), in: Capsule())
        }
        .padding(10)
    }

    private func tileButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Footer (hook + platform dots)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(clip.candidate.hook.isEmpty ? "Untitled moment" : clip.candidate.hook)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(clip.variants) { variant in
                    Image(systemName: variant.platform.symbolName)
                        .font(.caption2)
                        .foregroundStyle(variant.platform.tint)
                }
                Spacer()
                if let err = clip.exportError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange).help(err)
                }
                if let date = clip.scheduledDate {
                    Label(Self.shortDate(date), systemImage: "calendar")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.blue)
                        .help("Scheduled")
                } else if clip.publishReport != nil {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2).foregroundStyle(.green).help("Published")
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: date)
    }

    // MARK: - Download

    private func runSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = clip.suggestedFileName
        panel.canCreateDirectories = true
        panel.title = "Download short"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await clip.export(to: url) }
        }
    }
}

// MARK: - Mini phone

/// A small phone-framed, silent, looping preview of one clip.
private struct MiniPhone: View {
    let url: URL
    var overlayHook: String?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let radius = w * 0.15
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.03)],
                                         startPoint: .top, endPoint: .bottom))
                PhoneVideoPlayer(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: radius - 3, style: .continuous))
                    .padding(3)

                if let overlayHook, !overlayHook.trimmingCharacters(in: .whitespaces).isEmpty {
                    VStack(spacing: 0) {
                        Spacer().frame(height: w * 0.30)
                        Text(overlayHook)
                            .font(.system(size: w * 0.085, weight: .heavy))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, w * 0.05).padding(.vertical, w * 0.03)
                            .background(.black.opacity(0.55),
                                        in: RoundedRectangle(cornerRadius: w * 0.04))
                            .padding(.horizontal, w * 0.07)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

// MARK: - Player sheet (with sound + native controls)

struct ClipPlayerSheet: View {
    let url: URL
    /// When true, the clip is reframed to vertical 9:16 live, so the preview
    /// matches the published/downloaded file (the burned-in hook is export-only).
    var reframe: Bool = false
    var title: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.isEmpty ? "Preview" : title).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else if loading {
                    ProgressView("Preparing vertical preview…")
                        .controlSize(.large)
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 372, height: 660)
        }
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    private func load() async {
        if reframe {
            loading = true
            let item = await VerticalReframer.previewItem(clipURL: url, reframe: true)
            let p = item != nil ? AVPlayer(playerItem: item) : AVPlayer(url: url)
            p.play()
            player = p
            loading = false
        } else {
            let p = AVPlayer(url: url)
            p.play()
            player = p
        }
    }
}

// MARK: - Editor sheet (the full per-clip caption editor)

struct ClipEditorSheet: View {
    @Bindable var clip: ShortClip
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit short").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                ShortClipCard(clip: clip).padding(20)
            }
        }
        .frame(width: 920, height: 720)
    }
}
