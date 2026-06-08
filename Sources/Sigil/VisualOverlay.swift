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

/// Draws the compact confirmation card: a return glyph, the navigation target, and a countdown,
/// wrapped in a glowing "comet" that continuously circles the border leaving a fading trail.
final class VisualPopupView: NSView {
    private var label = ""
    private var secondsRemaining = 0

    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 9
    private let maxLabelChars = 48
    private let cornerRadius: CGFloat = 10
    private let borderWidth: CGFloat = 2.5
    /// Transparent inset around the card so the border glow can bloom without being clipped by the
    /// window edge.
    private let glowMargin: CGFloat = 7

    private let font = NSFont.systemFont(ofSize: 14, weight: .medium)

    /// Holds the rotating gradient and is masked to the rounded-rect border ring.
    private let glowContainer = CALayer()
    /// A conic gradient (one bright head fading to a transparent tail) that spins around the ring.
    private let glowGradient = CAGradientLayer()

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupGlow()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupGlow()
    }

    var contentSize: CGSize {
        let text = attributedText(forMeasurement: true)
        let size = text.size()
        return CGSize(
            width: (size.width + (horizontalPadding + glowMargin) * 2).rounded(),
            height: (size.height + (verticalPadding + glowMargin) * 2).rounded()
        )
    }

    func update(label: String, secondsRemaining: Int) {
        self.label = label
        self.secondsRemaining = secondsRemaining
        needsDisplay = true
    }

    private func setupGlow() {
        glowGradient.type = .conic
        glowGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowGradient.endPoint = CGPoint(x: 0.5, y: 0)
        glowContainer.addSublayer(glowGradient)
        glowContainer.shadowOffset = .zero
        layer?.addSublayer(glowContainer)
        applyGlowColors()

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 3
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        glowGradient.add(spin, forKey: "spin")
    }

    /// Colours the comet: transparent for most of the loop, then a bright head with a short fading
    /// tail. First and last stops match (transparent) so the loop is seamless.
    private func applyGlowColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let accent = isDark
            ? NSColor(srgbRed: 0.45, green: 0.85, blue: 0.55, alpha: 1)
            : NSColor(srgbRed: 0.18, green: 0.7, blue: 0.35, alpha: 1)
        let clear = accent.withAlphaComponent(0).cgColor
        glowGradient.colors = [clear, clear, accent.withAlphaComponent(0.45).cgColor, accent.cgColor, clear]
        glowGradient.locations = [0.0, 0.55, 0.82, 0.96, 1.0]
        glowContainer.shadowColor = accent.cgColor
        glowContainer.shadowRadius = 5
        glowContainer.shadowOpacity = 0.85
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGlowColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowContainer.frame = bounds
        // Mask the container to the border ring so the spinning gradient only shows along the edge.
        let ring = CAShapeLayer()
        let rect = bounds.insetBy(dx: glowMargin + borderWidth / 2, dy: glowMargin + borderWidth / 2)
        ring.path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ring.lineWidth = borderWidth
        ring.strokeColor = NSColor.black.cgColor
        ring.fillColor = NSColor.clear.cgColor
        glowContainer.mask = ring
        // A square at least as large as the diagonal keeps the bounds covered at every rotation.
        let side = hypot(bounds.width, bounds.height)
        glowGradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        glowGradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()

        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let cardRect = bounds.insetBy(dx: glowMargin, dy: glowMargin)
        let card = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)
        (isDark ? NSColor(white: 0.13, alpha: 0.98) : NSColor(white: 0.98, alpha: 0.98)).setFill()
        card.fill()
        (isDark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.14)).setStroke()
        card.lineWidth = 1
        card.stroke()

        let text = attributedText(forMeasurement: false)
        text.draw(at: CGPoint(x: glowMargin + horizontalPadding, y: glowMargin + verticalPadding))
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
