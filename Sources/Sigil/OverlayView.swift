import AppKit

/// One hint to render: a label anchored to its target element.
struct HintBox {
    /// Target element bounds in Cocoa global coordinates (bottom-left origin).
    let cocoaRect: CGRect
    let label: String
}

/// Draws every hint label in a single custom view for low overhead. Non-flipped (Cocoa)
/// coordinate space; all geometry is pre-converted to Cocoa global coordinates and offset by
/// the window's origin.
final class OverlayView: NSView {
    private var boxes: [HintBox] = []
    /// Global origin of the overlay window, used to map global rects into view-local space.
    private var originOffset: CGPoint = .zero
    /// The portion the user has already typed; only matching hints are drawn, with the typed
    /// prefix de-emphasised.
    private var typedPrefix: String = ""

    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private let horizontalPadding: CGFloat = 6
    private let verticalPadding: CGFloat = 3
    private let cornerRadius: CGFloat = 5

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    func update(boxes: [HintBox], originOffset: CGPoint, typedPrefix: String) {
        self.boxes = boxes
        self.originOffset = originOffset
        self.typedPrefix = typedPrefix
        needsDisplay = true
    }

    /// Change only the typed prefix, keeping the boxes already assigned to this view.
    func setTypedPrefix(_ prefix: String) {
        typedPrefix = prefix
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()

        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let palette = isDark ? Palette.dark : Palette.light

        for box in boxes where typedPrefix.isEmpty || box.label.hasPrefix(typedPrefix) {
            drawHint(box, palette: palette)
        }
    }

    private func drawHint(_ box: HintBox, palette: Palette) {
        let attributed = attributedLabel(for: box.label, palette: palette)
        let textSize = attributed.size()
        let boxWidth = (textSize.width + horizontalPadding * 2).rounded()
        let boxHeight = (textSize.height + verticalPadding * 2).rounded()

        // Element top-left corner in view-local coordinates.
        let localX = box.cocoaRect.minX - originOffset.x
        let localTopY = box.cocoaRect.maxY - originOffset.y

        var labelRect = CGRect(
            x: localX,
            y: localTopY - boxHeight,
            width: boxWidth,
            height: boxHeight
        )

        // Keep the label inside the view bounds.
        labelRect.origin.x = max(0, min(labelRect.origin.x, bounds.width - boxWidth))
        labelRect.origin.y = max(0, min(labelRect.origin.y, bounds.height - boxHeight))

        let path = NSBezierPath(roundedRect: labelRect, xRadius: cornerRadius, yRadius: cornerRadius)

        // Glossy base: vertical gradient, lighter at the top edge fading to a deeper tone.
        if let gradient = NSGradient(starting: palette.fillBottom, ending: palette.fillTop) {
            gradient.draw(in: path, angle: 90)
        } else {
            palette.fillBottom.setFill()
            path.fill()
        }

        // Top sheen for the "glossy" highlight, clipped to the rounded rect.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let sheenRect = CGRect(
            x: labelRect.minX,
            y: labelRect.midY,
            width: labelRect.width,
            height: labelRect.height / 2
        )
        if let sheen = NSGradient(starting: .clear, ending: palette.sheen) {
            sheen.draw(in: NSBezierPath(rect: sheenRect), angle: 90)
        }
        NSGraphicsContext.restoreGraphicsState()

        // Hairline border to crisp the edge.
        palette.border.setStroke()
        path.lineWidth = 1
        path.stroke()

        let textOrigin = CGPoint(
            x: labelRect.minX + horizontalPadding,
            y: labelRect.minY + verticalPadding
        )
        attributed.draw(at: textOrigin)
    }

    private func attributedLabel(for label: String, palette: Palette) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let matchedCount = min(typedPrefix.count, label.count)
        let matched = String(label.prefix(matchedCount))
        let remaining = String(label.dropFirst(matchedCount))

        if !matched.isEmpty {
            result.append(NSAttributedString(string: matched, attributes: [
                .font: font,
                .foregroundColor: palette.matchedText,
            ]))
        }
        if !remaining.isEmpty {
            result.append(NSAttributedString(string: remaining, attributes: [
                .font: font,
                .foregroundColor: palette.text,
            ]))
        }
        return result
    }
}

/// Theme-aware colors for a hint chip.
private struct Palette {
    let fillTop: NSColor      // top of the glossy gradient (lighter)
    let fillBottom: NSColor   // bottom of the glossy gradient (deeper)
    let sheen: NSColor        // top highlight for gloss
    let border: NSColor
    let text: NSColor         // untyped portion
    let matchedText: NSColor  // already-typed prefix (de-emphasised)

    /// Dark mode: shiny, almost-Apple-black finish with white text.
    static let dark = Palette(
        fillTop: NSColor(srgbRed: 0.24, green: 0.24, blue: 0.26, alpha: 0.98),
        fillBottom: NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 0.98),
        sheen: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.16),
        border: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.22),
        text: NSColor.white,
        matchedText: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.35)
    )

    /// Light mode: a soft grayish-blue chip with text even lighter than the chip.
    static let light = Palette(
        fillTop: NSColor(srgbRed: 0.50, green: 0.57, blue: 0.69, alpha: 0.97),
        fillBottom: NSColor(srgbRed: 0.34, green: 0.42, blue: 0.55, alpha: 0.97),
        sheen: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.30),
        border: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.45),
        text: NSColor(srgbRed: 0.98, green: 0.99, blue: 1.0, alpha: 1.0),
        matchedText: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.5)
    )
}
