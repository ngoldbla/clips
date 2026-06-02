import SwiftUI

/// One result card: a phone-style preview of the post for a single platform,
/// with the live video playing behind the real platform UI. Every line of copy
/// is editable in place.
struct PostPreviewCard: View {

    @Binding var variant: PostVariant
    let videoURL: URL
    /// When set, a visual approximation of the burned-in text hook is shown near
    /// the top of the preview (the real overlay is rendered at publish time).
    var overlayHook: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: variant.platform.symbolName)
                Text(variant.platform.displayName)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(variant.platform.tint)

            PhoneMockup(variant: $variant, videoURL: videoURL, overlayHook: overlayHook)
        }
    }
}

// MARK: - Phone

private struct PhoneMockup: View {
    @Binding var variant: PostVariant
    let videoURL: URL
    var overlayHook: String? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let bezel = max(4, w * 0.024)
            let bodyRadius = w * 0.14

            ZStack {
                RoundedRectangle(cornerRadius: bodyRadius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(white: 0.17), Color(white: 0.04)],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: bodyRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 14)

                PhoneScreen(variant: $variant,
                            videoURL: videoURL,
                            overlayHook: overlayHook,
                            w: w - bezel * 2)
                    .clipShape(RoundedRectangle(cornerRadius: bodyRadius - bezel * 0.7,
                                                style: .continuous))
                    .padding(bezel)
            }
        }
        .aspectRatio(0.485, contentMode: .fit)
    }
}

private struct PhoneScreen: View {
    @Binding var variant: PostVariant
    let videoURL: URL
    var overlayHook: String? = nil
    let w: CGFloat

    var body: some View {
        ZStack {
            Color.black
            PhoneVideoPlayer(url: videoURL)

            LinearGradient(colors: [.black.opacity(0.45), .clear],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.30))
            LinearGradient(colors: [.clear, .black.opacity(0.85)],
                           startPoint: UnitPoint(x: 0.5, y: 0.42), endPoint: .bottom)

            PlatformChrome(variant: $variant, w: w)

            // Burned-in text hook (visual approximation of the published render).
            if let overlayHook, !overlayHook.trimmingCharacters(in: .whitespaces).isEmpty {
                VStack(spacing: 0) {
                    Spacer().frame(height: w * 0.30)
                    Text(overlayHook)
                        .font(.system(size: w * 0.058, weight: .heavy))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, w * 0.045)
                        .padding(.vertical, w * 0.03)
                        .background(.black.opacity(0.55),
                                    in: RoundedRectangle(cornerRadius: w * 0.035))
                        .padding(.horizontal, w * 0.06)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // Dynamic Island
            VStack {
                Capsule(style: .continuous)
                    .fill(.black)
                    .frame(width: w * 0.30, height: w * 0.085)
                    .padding(.top, w * 0.05)
                Spacer()
            }
        }
    }
}

// MARK: - Platform UI overlay

private struct PlatformChrome: View {
    @Binding var variant: PostVariant
    let w: CGFloat

    private var skin: PlatformSkin { .skin(for: variant.platform) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: w * 0.03) {
                captionBlock
                Spacer(minLength: 0)
                ActionRail(skin: skin, w: w)
            }
            .padding(.horizontal, w * 0.045)
            .padding(.bottom, w * 0.07)
        }
    }

    private var topBar: some View {
        HStack {
            if let badge = skin.cornerBadge {
                Text(badge)
                    .font(.system(size: w * 0.058, weight: .heavy))
            }
            Spacer()
            Image(systemName: skin.topTrailingIcon)
                .font(.system(size: w * 0.052, weight: .semibold))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3)
        .padding(.horizontal, w * 0.05)
        .padding(.top, w * 0.165)
    }

    private var captionBlock: some View {
        VStack(alignment: .leading, spacing: w * 0.016) {
            HStack(spacing: w * 0.025) {
                Circle()
                    .fill(LinearGradient(
                        colors: [variant.platform.tint, variant.platform.tint.opacity(0.45)],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(Image(systemName: "person.fill")
                        .font(.system(size: w * 0.038))
                        .foregroundStyle(.white))
                    .frame(width: w * 0.078, height: w * 0.078)
                Text(skin.username)
                    .font(.system(size: w * 0.042, weight: .semibold))
                if let label = skin.actionLabel {
                    Text(label)
                        .font(.system(size: w * 0.034, weight: .bold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, w * 0.032)
                        .padding(.vertical, w * 0.014)
                        .background(skin.actionFilled
                                    ? AnyShapeStyle(skin.actionTint)
                                    : AnyShapeStyle(Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(.white.opacity(skin.actionFilled ? 0 : 0.85)))
                        .layoutPriority(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.bottom, w * 0.012)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: w * 0.016) {
                    EditableLine(text: $variant.hook, w: w, size: 0.047, weight: .semibold)
                    EditableLine(text: $variant.summary, w: w, size: 0.041, weight: .regular)
                    EditableLine(text: hashtagsBinding, w: w, size: 0.041, weight: .medium,
                                 tint: Color(red: 0.64, green: 0.83, blue: 1.0))
                }
            }
            .frame(maxHeight: w * 0.96)

            HStack(spacing: w * 0.022) {
                Image(systemName: "music.note")
                Text(skin.audioLabel).lineLimit(1)
            }
            .font(.system(size: w * 0.036, weight: .medium))
            .foregroundStyle(.white)
            .padding(.top, w * 0.014)
        }
        .frame(width: w * 0.64, alignment: .leading)
        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
    }

    private var hashtagsBinding: Binding<String> {
        Binding(
            get: { variant.hashtags.map { "#\($0)" }.joined(separator: " ") },
            set: { newValue in
                variant.hashtags = newValue
                    .split(whereSeparator: { " ,\n".contains($0) })
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
                    .filter { !$0.isEmpty }
            })
    }
}

/// A single line of post copy, styled like the overlay text but editable.
private struct EditableLine: View {
    @Binding var text: String
    let w: CGFloat
    let size: CGFloat
    let weight: Font.Weight
    var tint: Color = .white

    var body: some View {
        TextField("", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: w * size, weight: weight))
            .foregroundStyle(tint)
            .tint(.white)
    }
}

private struct ActionRail: View {
    let skin: PlatformSkin
    let w: CGFloat
    @State private var spin = false

    var body: some View {
        VStack(spacing: w * 0.052) {
            ForEach(skin.railItems.indices, id: \.self) { index in
                let item = skin.railItems[index]
                VStack(spacing: w * 0.012) {
                    Image(systemName: item.symbol)
                        .font(.system(size: w * 0.078, weight: .semibold))
                    if let caption = item.caption {
                        Text(caption).font(.system(size: w * 0.03, weight: .semibold))
                    }
                }
            }

            ZStack {
                Circle().fill(LinearGradient(
                    colors: [Color(white: 0.28), .black],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "music.note")
                    .font(.system(size: w * 0.048, weight: .bold))
            }
            .frame(width: w * 0.115, height: w * 0.115)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 6).repeatForever(autoreverses: false), value: spin)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
        .onAppear { spin = true }
    }
}

// MARK: - Per-platform styling

private struct PlatformSkin {
    struct RailItem { let symbol: String; let caption: String? }

    let username: String
    let cornerBadge: String?
    let topTrailingIcon: String
    let railItems: [RailItem]
    let actionLabel: String?
    let actionFilled: Bool
    let actionTint: Color
    let audioLabel: String

    static func skin(for platform: SocialPlatform) -> PlatformSkin {
        switch platform {
        case .tiktok:
            PlatformSkin(
                username: "@tu_cuenta",
                cornerBadge: nil,
                topTrailingIcon: "magnifyingglass",
                railItems: [
                    RailItem(symbol: "heart.fill", caption: "12.4K"),
                    RailItem(symbol: "ellipsis.bubble.fill", caption: "318"),
                    RailItem(symbol: "bookmark.fill", caption: "1.2K"),
                    RailItem(symbol: "arrowshape.turn.up.right.fill", caption: "504"),
                ],
                actionLabel: nil, actionFilled: false, actionTint: .clear,
                audioLabel: "sonido original")
        case .instagram:
            PlatformSkin(
                username: "@tu_cuenta",
                cornerBadge: "Reels",
                topTrailingIcon: "camera",
                railItems: [
                    RailItem(symbol: "heart", caption: "8.2K"),
                    RailItem(symbol: "bubble.right", caption: "204"),
                    RailItem(symbol: "paperplane", caption: "97"),
                    RailItem(symbol: "ellipsis", caption: nil),
                ],
                actionLabel: "Seguir", actionFilled: false, actionTint: .clear,
                audioLabel: "audio original")
        case .youtube:
            PlatformSkin(
                username: "@tu_canal",
                cornerBadge: "Shorts",
                topTrailingIcon: "magnifyingglass",
                railItems: [
                    RailItem(symbol: "hand.thumbsup.fill", caption: "5.7K"),
                    RailItem(symbol: "hand.thumbsdown.fill", caption: nil),
                    RailItem(symbol: "ellipsis.bubble.fill", caption: "146"),
                    RailItem(symbol: "arrowshape.turn.up.right.fill", caption: nil),
                ],
                actionLabel: "Suscribirse", actionFilled: true,
                actionTint: Color(hex: "FF0000"),
                audioLabel: "Sonido original")
        }
    }
}
