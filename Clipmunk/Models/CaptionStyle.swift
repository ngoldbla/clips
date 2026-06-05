import AppKit
import Foundation

/// Visual style for burned-in, word-level captions.
///
/// Holds only `Sendable` primitive descriptors — font family + weight token,
/// size as a fraction of the render width, colors as hex strings — so it crosses
/// the `nonisolated` caption-render boundary safely under Swift 6 strict
/// concurrency. The `NSFont`/`NSColor` objects are reconstructed *locally* inside
/// the renderer via the helpers below; non-`Sendable` AppKit objects never cross
/// isolation. Persisted in settings by `id`, not by archiving the struct.
struct CaptionStyle: Sendable, Equatable, Codable, Identifiable {

    /// System-font weight, as a `Sendable`/`Codable` token.
    enum Weight: String, Sendable, Codable {
        case regular, medium, semibold, bold, heavy, black
        var ns: NSFont.Weight {
            switch self {
            case .regular:  .regular
            case .medium:   .medium
            case .semibold: .semibold
            case .bold:     .bold
            case .heavy:    .heavy
            case .black:    .black
            }
        }
    }

    /// Where the caption band sits in the 9:16 frame.
    enum Position: String, Sendable, Codable { case bottom, center }

    /// How the currently-spoken word is emphasized.
    enum Highlight: String, Sendable, Codable {
        case none   // whole line one color, no active-word emphasis
        case color  // recolor the active word
        case box    // filled rounded box behind the active word (karaoke)
    }

    let id: String
    let name: String

    /// Font family; `nil` = San Francisco system font at `weight`.
    var fontName: String?
    var weight: Weight
    /// Font size as a fraction of the render width (0.06 ≈ 65pt at 1080w).
    var sizeRatio: Double
    var uppercase: Bool

    var textColorHex: String
    /// Active word's text color (used by `.color` and `.box`).
    var highlightTextColorHex: String
    /// Fill behind the active word (used by `.box`).
    var highlightFillHex: String
    var highlight: Highlight

    /// `NSAttributedString.strokeWidth` magnitude as a % of font size; the
    /// renderer negates it for a fill+stroke outline. 0 = no outline.
    var outlinePercent: Double
    var strokeColorHex: String

    var position: Position

    /// How much the active word scales up while it's spoken (1 = no "pop").
    var activeScale: Double = 1

    // MARK: - Reconstruction (call inside nonisolated render code)

    func font(forRenderWidth width: CGFloat) -> NSFont {
        let size = max(18, width * sizeRatio)
        if let fontName, let f = NSFont(name: fontName, size: size) { return f }
        return NSFont.systemFont(ofSize: size, weight: weight.ns)
    }
    var textColor: NSColor { NSColor(captionHex: textColorHex) }
    var highlightTextColor: NSColor { NSColor(captionHex: highlightTextColorHex) }
    var highlightFill: NSColor { NSColor(captionHex: highlightFillHex) }
    var strokeColor: NSColor { NSColor(captionHex: strokeColorHex) }

    func display(_ text: String) -> String { uppercase ? text.uppercased() : text }

    // MARK: - Presets (Your Call #2 — sensible defaults)

    /// "Bold White" — the clean classic: white text, black outline, the active
    /// word flips to bright yellow. The default.
    static let boldWhite = CaptionStyle(
        id: "bold-white", name: "Bold White",
        fontName: nil, weight: .heavy, sizeRatio: 0.062, uppercase: false,
        textColorHex: "FFFFFF", highlightTextColorHex: "FFD60A",
        highlightFillHex: "FFD60A", highlight: .color,
        outlinePercent: 7, strokeColorHex: "000000", position: .bottom,
        activeScale: 1.06)

    /// "Hormozi" — uppercase karaoke: white text, heavy outline, a filled green
    /// box snaps onto the active word.
    static let hormozi = CaptionStyle(
        id: "hormozi", name: "Hormozi",
        fontName: nil, weight: .black, sizeRatio: 0.066, uppercase: true,
        textColorHex: "FFFFFF", highlightTextColorHex: "000000",
        highlightFillHex: "39E75F", highlight: .box,
        outlinePercent: 9, strokeColorHex: "000000", position: .bottom,
        activeScale: 1.04)

    /// "Pop" — energetic and centered: white text, light outline, the active
    /// word bursts hot-pink (the renderer also scales it up).
    static let pop = CaptionStyle(
        id: "pop", name: "Pop",
        fontName: nil, weight: .heavy, sizeRatio: 0.072, uppercase: false,
        textColorHex: "FFFFFF", highlightTextColorHex: "FF2D95",
        highlightFillHex: "FF2D95", highlight: .color,
        outlinePercent: 4, strokeColorHex: "000000", position: .center,
        activeScale: 1.16)

    /// "Clean" — minimal/subtle: semibold white, faint outline, no active-word
    /// emphasis. For talking-head clips where loud captions would distract.
    static let clean = CaptionStyle(
        id: "clean", name: "Clean",
        fontName: nil, weight: .semibold, sizeRatio: 0.052, uppercase: false,
        textColorHex: "FFFFFF", highlightTextColorHex: "FFFFFF",
        highlightFillHex: "FFFFFF", highlight: .none,
        outlinePercent: 3, strokeColorHex: "000000", position: .bottom)

    static let presets: [CaptionStyle] = [boldWhite, hormozi, pop, clean]
    static let `default` = boldWhite

    /// The preset with this id, or the default if unknown.
    static func preset(id: String?) -> CaptionStyle {
        presets.first { $0.id == id } ?? `default`
    }
}

extension NSColor {
    /// Builds an `NSColor` from a 6- or 8-digit (RRGGBBAA) sRGB hex string.
    /// Free of any isolation concern — created locally where it's used.
    convenience init(captionHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b, a: CGFloat
        if cleaned.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
