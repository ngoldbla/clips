import AVFoundation
import AppKit
import QuartzCore

/// Builds the Core Animation layer tree for animated, word-level captions, to be
/// composited into the SAME export pass as the reframe/hook (one
/// `AVVideoCompositionCoreAnimationTool`, no extra re-encode).
///
/// Peer of `VideoOverlayRenderer`: like the hook band, every piece of text is a
/// **pre-rasterized `CGImage`** (CATextLayer mis-renders in AVFoundation's
/// offline render server), and timing rides on `CAKeyframeAnimation`s anchored to
/// `AVCoreAnimationBeginTimeAtZero`.
///
/// Times in the `CaptionScript` are clip-relative (0 = clip start); `total` is the
/// clip's duration in seconds, used to normalize keyframe `keyTimes` into 0…1.
enum CaptionRenderer {

    /// A parent `CALayer` (sized to `renderSize`) holding one sub-layer per
    /// caption line. Returns nil when there's nothing to draw.
    static func layer(
        for script: CaptionScript, renderSize: CGSize,
        style: CaptionStyle, total: Double
    ) -> CALayer? {
        guard !script.isEmpty, total > 0 else { return nil }

        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)

        let font = style.font(forRenderWidth: renderSize.width)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let maxLineWidth = renderSize.width * 0.92

        // Caption band centre, in Core Animation's bottom-left space.
        let bandCenterY = style.position == .center
            ? renderSize.height * 0.5
            : renderSize.height * 0.18

        for line in script.lines {
            guard let lineLayer = makeLineLayer(
                line: line, renderSize: renderSize, bandCenterY: bandCenterY,
                font: font, spaceWidth: spaceWidth, maxLineWidth: maxLineWidth,
                style: style, total: total)
            else { continue }
            parent.addSublayer(lineLayer)
        }
        return parent.sublayers?.isEmpty == false ? parent : nil
    }

    // MARK: - One line

    private static func makeLineLayer(
        line: CaptionLine, renderSize: CGSize, bandCenterY: CGFloat,
        font: NSFont, spaceWidth: CGFloat, maxLineWidth: CGFloat,
        style: CaptionStyle, total: Double
    ) -> CALayer? {
        // Measure each word, then scale the whole line down if it would overflow
        // the safe width (grouping caps length, but a long word can still spill).
        let displays = line.words.map { style.display($0.text) }
        let baseWidths = displays.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        let rawWidth = baseWidths.reduce(0, +) + spaceWidth * CGFloat(max(0, line.words.count - 1))
        guard rawWidth > 0 else { return nil }
        let scale = min(1, maxLineWidth / rawWidth)
        let lineFont = scale < 1
            ? NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
            : font

        let lineLayer = CALayer()
        lineLayer.frame = CGRect(origin: .zero, size: renderSize)

        // Lay the words out left→right, centred as a group on bandCenterY. Each
        // entry carries the word's active window so a skipped rasterization can't
        // desync timing from `line.words`.
        struct WordImage { let img: CGImage; let hi: CGImage?; let box: Bool; let size: CGSize; let start: Double; let end: Double }
        var images: [WordImage] = []
        var totalWidth: CGFloat = 0
        let gap = spaceWidth * scale
        for (idx, display) in displays.enumerated() {
            guard let base = textImage(display, font: lineFont,
                                       fill: style.textColor, stroke: style.strokeColor,
                                       outlinePercent: style.outlinePercent)
            else { continue }
            let hi: CGImage? = style.highlight == .none ? nil
                : textImage(display, font: lineFont,
                            fill: style.highlightTextColor, stroke: style.strokeColor,
                            outlinePercent: style.outlinePercent)?.img
            // Hold the highlight until the next word starts (snappier karaoke).
            let activeEnd = idx + 1 < line.words.count ? line.words[idx + 1].start : line.end
            images.append(WordImage(img: base.img, hi: hi, box: style.highlight == .box,
                                    size: base.size, start: line.words[idx].start, end: activeEnd))
            totalWidth += base.size.width
        }
        guard !images.isEmpty else { return nil }
        totalWidth += gap * CGFloat(images.count - 1)

        var cursorX = (renderSize.width - totalWidth) / 2
        for entry in images {
            let w = entry.size.width, h = entry.size.height
            let container = CALayer()
            container.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            container.position = CGPoint(x: cursorX + w / 2, y: bandCenterY)
            container.anchorPoint = CGPoint(x: 0.5, y: 0.5)

            // Optional karaoke box behind the word, shown during its window.
            if entry.box {
                let pad = h * 0.10
                let box = CALayer()
                box.frame = CGRect(x: -pad, y: -pad * 0.4, width: w + pad * 2, height: h + pad * 0.2)
                box.backgroundColor = style.highlightFill.cgColor
                box.cornerRadius = (h + pad * 0.2) * 0.16
                box.opacity = 0
                addWindow(to: box, keyPath: "opacity", from: 0, to: 1,
                          start: entry.start, end: entry.end, total: total)
                container.addSublayer(box)
            }

            container.addSublayer(imageLayer(entry.img, size: CGSize(width: w, height: h)))

            if let hi = entry.hi {
                let hiLayer = imageLayer(hi, size: CGSize(width: w, height: h))
                hiLayer.opacity = 0
                addWindow(to: hiLayer, keyPath: "opacity", from: 0, to: 1,
                          start: entry.start, end: entry.end, total: total)
                container.addSublayer(hiLayer)
            }

            // "Pop": scale the word up while it's spoken.
            if style.activeScale != 1 {
                addWindow(to: container, keyPath: "transform.scale",
                          from: 1, to: style.activeScale,
                          start: entry.start, end: entry.end, total: total)
            }

            lineLayer.addSublayer(container)
            cursorX += w + gap
        }

        // Reveal the whole line only across its own time window.
        lineLayer.opacity = 0
        addWindow(to: lineLayer, keyPath: "opacity", from: 0, to: 1,
                  start: line.start, end: line.end, total: total, fade: 0.08)
        return lineLayer
    }

    // MARK: - Layers & animation

    private static func imageLayer(_ image: CGImage, size: CGSize) -> CALayer {
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: size)
        layer.contentsScale = 3
        layer.contents = image
        return layer
    }

    /// A `[from, from, to, to, from, from]` keyframe animation that holds `from`
    /// until `start`, ramps to `to`, holds, then ramps back — the building block
    /// for both line visibility and per-word highlight/pop.
    private static func addWindow(
        to layer: CALayer, keyPath: String, from: Double, to: Double,
        start: Double, end: Double, total: Double, fade: Double = 0.05
    ) {
        let s = max(0, min(start, total))
        let e = max(s, min(end, total))
        let f = min(fade, max(0.0001, (e - s) / 2))
        let k1 = s / total
        let k2 = min(1, (s + f) / total)
        let k3 = max(k2, (e - f) / total)
        let k4 = min(1, max(k3, e / total))

        let anim = CAKeyframeAnimation(keyPath: keyPath)
        anim.values = [from, from, to, to, from, from]
        anim.keyTimes = [0, k1, k2, k3, k4, 1].map { NSNumber(value: $0) }
        anim.duration = total
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        layer.add(anim, forKey: keyPath)
    }

    // MARK: - Rasterization

    /// Renders one word to a tightly-sized 3× bitmap (fill + optional outline),
    /// returning the image and its point size. Mirrors
    /// `VideoOverlayRenderer.renderTextImage`'s offline-safe approach.
    private static func textImage(
        _ text: String, font: NSFont, fill: NSColor, stroke: NSColor, outlinePercent: Double
    ) -> (img: CGImage, size: CGSize)? {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fill, .paragraphStyle: para]
        if outlinePercent > 0 {
            attrs[.strokeColor] = stroke
            attrs[.strokeWidth] = -outlinePercent
        }
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let bounds = attributed.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let pad = ceil(font.pointSize * outlinePercent / 100) + 4
        let size = CGSize(width: ceil(bounds.width) + pad * 2, height: ceil(bounds.height) + pad * 2)

        let scale: CGFloat = 3
        let pxW = max(1, Int(size.width * scale))
        let pxH = max(1, Int(size.height * scale))
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        ctx.scaleBy(x: scale, y: scale)
        let y = (size.height - bounds.height) / 2
        attributed.draw(with: CGRect(x: pad, y: y, width: ceil(bounds.width) + 1, height: ceil(bounds.height)),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return nil }
        return (image, size)
    }
}
