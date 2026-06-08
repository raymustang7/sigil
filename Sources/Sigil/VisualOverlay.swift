import AppKit

/// A small, click-through confirmation popup shown beside the unique best match in Visual mode:
/// "↵ navigate to <label>  ·  Ns". There is no query box — typed keys are captured silently by
/// the global `InputTap` — so this is the mode's only on-screen panel, and it appears only when a
/// single element matches. It never becomes key, keeping the underlying app focused.
final class VisualOverlayController {
    private var window: NSWindow?
    private var view: VisualPopupView?

    /// Show the popup centred horizontally, one third of the way down from the top of the active
    /// screen — a fixed, predictable spot rather than tracking the matched element.
    func show(label: String, secondsRemaining: Int) {
        let window = ensureWindow()
        view?.update(label: label, secondsRemaining: secondsRemaining)
        let size = view?.contentSize ?? .zero
        view?.frame = CGRect(origin: .zero, size: size)
        position(window, size: size)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = VisualPopupView(frame: .zero)
        panel.contentView = view

        self.window = panel
        self.view = view
        return panel
    }

    /// Centre horizontally; place the popup's centre one third down from the top of the screen.
    private func position(_ window: NSWindow, size: CGSize) {
        guard let area = NSScreen.main?.visibleFrame else {
            window.setFrame(CGRect(origin: .zero, size: size), display: true)
            return
        }
        let centreY = area.maxY - area.height / 3
        let origin = CGPoint(
            x: area.midX - size.width / 2,
            y: centreY - size.height / 2
        )
        window.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

/// Draws the compact confirmation card: a return glyph, the navigation target, and a countdown.
final class VisualPopupView: NSView {
    private var label = ""
    private var secondsRemaining = 0

    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 9
    private let maxLabelChars = 48

    private let font = NSFont.systemFont(ofSize: 14, weight: .medium)

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    var contentSize: CGSize {
        let text = attributedText(forMeasurement: true)
        let size = text.size()
        return CGSize(
            width: (size.width + horizontalPadding * 2).rounded(),
            height: (size.height + verticalPadding * 2).rounded()
        )
    }

    func update(label: String, secondsRemaining: Int) {
        self.label = label
        self.secondsRemaining = secondsRemaining
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()

        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let card = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        (isDark ? NSColor(white: 0.13, alpha: 0.98) : NSColor(white: 0.98, alpha: 0.98)).setFill()
        card.fill()
        (isDark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.14)).setStroke()
        card.lineWidth = 1
        card.stroke()

        let text = attributedText(forMeasurement: false)
        text.draw(at: CGPoint(x: horizontalPadding, y: verticalPadding))
    }

    /// "↵ navigate to <label>  ·  Ns". For measurement we use the full label so the card never
    /// resizes mid-countdown; for drawing we truncate overly long labels.
    private func attributedText(forMeasurement: Bool) -> NSAttributedString {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let accent = isDark
            ? NSColor(srgbRed: 0.45, green: 0.85, blue: 0.55, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.55, blue: 0.25, alpha: 1)
        let textColor = isDark ? NSColor.white : NSColor.black
        let dimColor = isDark ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0, alpha: 0.5)

        let shown = forMeasurement ? label : truncate(label)
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "↵", attributes: [.font: font, .foregroundColor: accent]))
        result.append(NSAttributedString(string: "  go to ", attributes: [.font: font, .foregroundColor: dimColor]))
        result.append(NSAttributedString(string: shown, attributes: [.font: font, .foregroundColor: textColor]))
        result.append(NSAttributedString(string: "   ·  \(secondsRemaining)s", attributes: [.font: font, .foregroundColor: dimColor]))
        return result
    }

    private func truncate(_ text: String) -> String {
        guard text.count > maxLabelChars else { return text }
        return String(text.prefix(maxLabelChars - 1)) + "…"
    }
}
