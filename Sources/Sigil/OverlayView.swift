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

        // Flat fill with a soft drop shadow so the chip lifts off whatever is underneath.
        let path = NSBezierPath(roundedRect: labelRect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        palette.shadow.set()
        palette.fill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Hairline edge, inset half a point so it sits crisply on the pixel grid. Its tone
        // contrasts with the chip so the hint stays visible on both light and dark pages.
        let edge = NSBezierPath(
            roundedRect: labelRect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius - 0.5,
            yRadius: cornerRadius - 0.5
        )
        edge.lineWidth = 1
        palette.edge.setStroke()
        edge.stroke()

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

/// Theme-aware colors for a hint chip, drawn from the earthy sage palette.
private struct Palette {
    let fill: NSColor
    let edge: NSColor         // 1px hairline around the chip
    let shadow: NSShadow
    let text: NSColor         // untyped portion
    let matchedText: NSColor  // already-typed prefix

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    private static func dropShadow(alpha: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: alpha)
        shadow.shadowOffset = NSSize(width: 0, height: -1) // non-flipped: negative y is down
        shadow.shadowBlurRadius = 3
        return shadow
    }

    // Palette tokens.
    private static let ivory: UInt32 = 0xF4F3F1
    private static let sage: UInt32 = 0xA1A79E
    private static let forest: UInt32 = 0x4E5A53
    private static let pine: UInt32 = 0x3A443E
    private static let ink: UInt32 = 0x232A26

    /// Light mode: Sage chip, Ink text, typed prefix fades to Ivory, Forest edge.
    static let light = Palette(
        fill: rgb(sage, alpha: 0.98),
        edge: rgb(forest, alpha: 0.6),
        shadow: dropShadow(alpha: 0.22),
        text: rgb(ink),
        matchedText: rgb(ivory)
    )

    /// Dark mode: Pine chip, Ivory text, typed prefix in Sage, Sage edge so the chip holds up
    /// on dark pages.
    static let dark = Palette(
        fill: rgb(pine, alpha: 0.98),
        edge: rgb(sage, alpha: 0.75),
        shadow: dropShadow(alpha: 0.35),
        text: rgb(ivory),
        matchedText: rgb(sage)
    )
}
