import SwiftUI

/// The long-video pipeline progress screen. Shows the source video in a
/// cinematic, aspect-correct frame (no weird phone crop for horizontal video)
/// with a sweeping "scanner" and a filmstrip that lights up cell by cell — so it
/// reads as the AI watching the timeline and cutting the best moments.
struct ShortsProgressView: View {

    @Environment(WorkspaceModel.self) private var workspace
    @Environment(ModelManager.self) private var modelManager

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

            if let url = workspace.job?.url {
                CinematicScanner(url: url)
                    .frame(width: 560, height: 315)   // 16:9
                    .shadow(color: .black.opacity(0.35), radius: 26, y: 16)
            }

            FilmstripLoader()
                .frame(width: 560, height: 30)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(headline).font(.title3.weight(.semibold))
                }
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                if let job = workspace.job {
                    Text("\(job.fileName)  ·  \(job.durationLabel)")
                        .font(.footnote).foregroundStyle(.tertiary)
                }
            }

            Button(role: .cancel) {
                workspace.cancelPipeline()
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .padding(.top, 2)

            Spacer()
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headline: String {
        switch workspace.phase {
        case .transcribing:
            switch workspace.transcription.phase {
            case .downloadingModel: return "Downloading the transcription model…"
            case .preparingModel:   return "Preparing the model…"
            default:                return "Transcribing your video…"
            }
        case .findingMoments:
            switch modelManager.momentFinder.phase {
            case .downloading(_): return "Downloading \(modelManager.momentFinder.displayName)…"
            case .loading:        return "Loading \(modelManager.momentFinder.displayName)…"
            default:              return "Finding the best moments…"
            }
        default:
            return "Working…"
        }
    }

    private var detail: String? {
        switch workspace.phase {
        case .transcribing:
            switch workspace.transcription.phase {
            case .downloadingModel(let f): return "First run only — \(Int(f * 100))%"
            case .preparingModel:          return "First run only — optimizing for your Mac. This can take a minute or two."
            default:                       return "Reading the whole timeline."
            }
        case .findingMoments:
            switch modelManager.momentFinder.phase {
            case .downloading(let f): return "First run only — downloading the model (\(Int(f * 100))%)"
            case .loading:            return "First run only — preparing the model for your Mac."
            default:
                return "\(modelManager.momentFinder.displayName) is scanning the transcript — this can take a few minutes."
            }
        default:
            return nil
        }
    }
}

// MARK: - Cinematic scanner

private struct CinematicScanner: View {
    let url: URL
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black)

                PhoneVideoPlayer(url: url, gravity: .resizeAspect)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                // Subtle cinematic vignette.
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(
                        colors: [.black.opacity(0.35), .clear, .black.opacity(0.35)],
                        startPoint: .top, endPoint: .bottom))

                // Sweeping scanner line.
                LinearGradient(
                    colors: [.clear, Color.accentColor.opacity(0.9), .clear],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: 90)
                    .blur(radius: 6)
                    .offset(x: sweep ? (w / 2 - 45) : -(w / 2 - 45))
                    .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: sweep)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                CornerBrackets()
                    .stroke(Color.white.opacity(0.85), lineWidth: 2)
                    .padding(12)

                // "Live" badge.
                VStack {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                            .opacity(sweep ? 1 : 0.3)
                        Text("ANALYZING")
                            .font(.system(size: 10, weight: .heavy)).kerning(1.5)
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.top, 14)
                    Spacer()
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(sweep ? 0.9 : 0.25), lineWidth: 2)
                    .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: sweep))
        }
        .onAppear { sweep = true }
    }
}

/// Four L-shaped corner marks, like a camera's framing guides.
private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let len = min(rect.width, rect.height) * 0.07
        let corners = [
            (rect.minX, rect.minY, 1.0, 1.0),
            (rect.maxX, rect.minY, -1.0, 1.0),
            (rect.minX, rect.maxY, 1.0, -1.0),
            (rect.maxX, rect.maxY, -1.0, -1.0),
        ]
        for (x, y, sx, sy) in corners {
            p.move(to: CGPoint(x: x + len * sx, y: y))
            p.addLine(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x, y: y + len * sy))
        }
        return p
    }
}

// MARK: - Filmstrip loader

/// A horizontal filmstrip whose cells light up in sequence — the "cutting" beat.
private struct FilmstripLoader: View {
    private let cells = 9

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let active = Int(t * 3) % cells
            HStack(spacing: 4) {
                ForEach(0..<cells, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i == active
                              ? AnyShapeStyle(Color.accentColor)
                              : AnyShapeStyle(Color.secondary.opacity(0.22)))
                        .overlay(
                            HStack {
                                Circle().fill(.black.opacity(0.35)).frame(width: 3, height: 3)
                                Spacer()
                                Circle().fill(.black.opacity(0.35)).frame(width: 3, height: 3)
                            }
                            .padding(.horizontal, 3))
                        .scaleEffect(i == active ? 1.0 : 0.92)
                        .animation(.easeOut(duration: 0.2), value: active)
                }
            }
        }
    }
}
