import AppKit
import CoreText

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

/// A full-screen, click-through "warp" effect for Visual-mode activation: glowing text rushes in
/// from filling the whole screen down to its resting size at the centre, over a brief dark radial
/// vignette — like dropping into a new galaxy. The reverse (text expanding away) plays on exit.
final class VisualWarpController {
    private var window: NSWindow?
    private var host: NSView?
    private var backdrop: CAGradientLayer?
    private var textLayer: CATextLayer?
    private var hideWork: DispatchWorkItem?

    private let enterDuration: TimeInterval = 1.5
    private let exitDuration: TimeInterval = 1.0

    func play(_ text: String, entering: Bool) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let window = ensureWindow()
        window.setFrame(frame, display: true)
        host?.frame = CGRect(origin: .zero, size: frame.size)
        configure(text: text, size: frame.size, scale: screen.backingScaleFactor)

        hideWork?.cancel()
        window.orderFrontRegardless()
        animate(entering: entering)

        let total = entering ? enterDuration : exitDuration
        let work = DispatchWorkItem { [weak self] in self?.window?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + total, execute: work)
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
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView(frame: .zero)
        view.wantsLayer = true
        panel.contentView = view
        host = view

        let back = CAGradientLayer()
        back.type = .radial
        back.startPoint = CGPoint(x: 0.5, y: 0.5)
        back.endPoint = CGPoint(x: 1, y: 1)
        view.layer?.addSublayer(back)
        backdrop = back

        let text = CATextLayer()
        text.alignmentMode = .center
        text.truncationMode = .none
        text.isWrapped = false
        text.foregroundColor = NSColor.white.cgColor
        text.shadowColor = NSColor.white.cgColor
        text.shadowRadius = 16
        text.shadowOpacity = 0.9
        text.shadowOffset = .zero
        text.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        view.layer?.addSublayer(text)
        textLayer = text

        window = panel
        return panel
    }

    private func configure(text: String, size: CGSize, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.frame = CGRect(origin: .zero, size: size)
        backdrop?.colors = [
            NSColor(white: 0.0, alpha: 0.0).cgColor,
            NSColor(white: 0.02, alpha: 0.62).cgColor,
        ]
        backdrop?.locations = [0.0, 1.0]

        let font = NSFont.systemFont(ofSize: 46, weight: .bold)
        let lineHeight = ceil(font.ascender - font.descender)
        textLayer?.font = font
        textLayer?.fontSize = font.pointSize
        textLayer?.string = text.uppercased()
        textLayer?.contentsScale = scale
        textLayer?.bounds = CGRect(x: 0, y: 0, width: size.width, height: lineHeight)
        textLayer?.position = CGPoint(x: size.width / 2, y: size.height / 2)
        CATransaction.commit()
    }

    private func animate(entering: Bool) {
        guard let textLayer, let backdrop else { return }
        let dur = entering ? enterDuration : exitDuration

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        if entering {
            // Rush in from huge → resting, then hold so the title lands and reads.
            scale.values = [7.0, 1.0, 1.0]
            scale.keyTimes = [0.0, 0.5, 1.0]
            scale.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear)]
        } else {
            // Fly back out into the distance.
            scale.values = [1.0, 6.0]
            scale.keyTimes = [0.0, 1.0]
            scale.timingFunctions = [CAMediaTimingFunction(name: .easeIn)]
        }
        scale.duration = dur
        scale.isRemovedOnCompletion = false
        scale.fillMode = .forwards

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = entering ? [0.0, 1.0, 1.0, 0.0] : [1.0, 0.0]
        opacity.keyTimes = entering ? [0.0, 0.2, 0.65, 1.0] : [0.0, 1.0]
        opacity.duration = dur
        opacity.isRemovedOnCompletion = false
        opacity.fillMode = .forwards

        textLayer.removeAllAnimations()
        textLayer.add(scale, forKey: "scale")
        textLayer.add(opacity, forKey: "opacity")

        let backOp = CAKeyframeAnimation(keyPath: "opacity")
        backOp.values = entering ? [0.0, 1.0, 0.0] : [0.7, 0.0]
        backOp.keyTimes = entering ? [0.0, 0.35, 1.0] : [0.0, 1.0]
        backOp.duration = dur
        backOp.isRemovedOnCompletion = false
        backOp.fillMode = .forwards
        backdrop.removeAllAnimations()
        backdrop.add(backOp, forKey: "op")
    }
}

/// A brief, click-through "toast" shown when Visual mode is toggled — "VISUAL MODE ACTIVATED" /
/// "DEACTIVATED" in a black-and-gold Batman style. It fades in, holds, then fades out on its own,
/// and never becomes key so the underlying app keeps focus.
final class VisualToastController {
    private var window: NSWindow?
    private var view: VisualToastView?
    private var hideWork: DispatchWorkItem?

    private let fadeIn: TimeInterval = 0.16
    private let hold: TimeInterval = 0.95
    private let fadeOut: TimeInterval = 0.5

    func show(_ text: String) {
        let window = ensureWindow()
        view?.text = text
        let size = view?.contentSize ?? .zero
        view?.frame = CGRect(origin: .zero, size: size)
        position(window, size: size)

        // Restart cleanly if a previous toast is still on screen.
        hideWork?.cancel()
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeIn
            window.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.fade(out: window) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeIn + hold, execute: work)
    }

    private func fade(out window: NSWindow) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeOut
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })
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

        let view = VisualToastView(frame: .zero)
        panel.contentView = view

        self.window = panel
        self.view = view
        return panel
    }

    /// Centre horizontally, a little above the vertical centre of the active screen.
    private func position(_ window: NSWindow, size: CGSize) {
        guard let area = NSScreen.main?.visibleFrame else {
            window.setFrame(CGRect(origin: .zero, size: size), display: true)
            return
        }
        let centreY = area.midY + area.height * 0.08
        let origin = CGPoint(x: area.midX - size.width / 2, y: centreY - size.height / 2)
        window.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

/// A small, persistent, click-through HUD pinned to the bottom-right of the active screen that
/// mirrors the keys captured so far in Visual mode — a grey box with white text. Shown only while a
/// query is being built; hidden when the query is empty, the mode is paused, or the mode exits.
final class VisualQueryHUDController {
    private var window: NSWindow?
    private var view: VisualQueryHUDView?
    private let margin: CGFloat = 24

    func show(_ text: String) {
        let window = ensureWindow()
        view?.text = text
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

        let view = VisualQueryHUDView(frame: .zero)
        panel.contentView = view

        self.window = panel
        self.view = view
        return panel
    }

    private func position(_ window: NSWindow, size: CGSize) {
        guard let area = NSScreen.main?.visibleFrame else {
            window.setFrame(CGRect(origin: .zero, size: size), display: true)
            return
        }
        let origin = CGPoint(x: area.maxX - size.width - margin, y: area.minY + margin)
        window.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

/// Draws the query HUD: a grey rounded box with the captured keys in white.
final class VisualQueryHUDView: NSView {
    var text = "" { didSet { needsDisplay = true } }

    private let horizontalPadding: CGFloat = 12
    private let verticalPadding: CGFloat = 8
    private let cornerRadius: CGFloat = 8
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)

    override var isOpaque: Bool { false }

    private var attributed: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
        ])
    }

    var contentSize: CGSize {
        let size = attributed.size()
        return CGSize(
            width: (size.width + horizontalPadding * 2).rounded(),
            height: (size.height + verticalPadding * 2).rounded()
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()

        let box = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(white: 0.22, alpha: 0.95).setFill()
        box.fill()

        let str = attributed
        let textSize = str.size()
        str.draw(at: CGPoint(
            x: horizontalPadding,
            y: (bounds.height - textSize.height) / 2
        ))
    }
}

/// Draws the toast as a brushed-metal plaque: a borderless rounded card filled with a vertical
/// greyscale gradient and a soft top sheen, with the uppercase text filled by its own metallic
/// gradient and a subtle emboss. Strictly monochrome — black through white.
final class VisualToastView: NSView {
    var text = "" { didSet { needsDisplay = true } }

    private let horizontalPadding: CGFloat = 24
    private let verticalPadding: CGFloat = 14
    private let cornerRadius: CGFloat = 13

    private let font = NSFont.systemFont(ofSize: 15, weight: .heavy)

    /// A small tile of fine greyscale grain, generated once. Tiled over the card it gives the
    /// micro-texture of a matte / soft-touch finish (the main thing that separates matte from gloss).
    private static let grain: NSImage = makeGrain(side: 110)

    override var isOpaque: Bool { false }

    private var attributed: NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: font,
            .foregroundColor: NSColor.white, // colour unused (text is gradient-filled), kept for sizing
            .kern: 2.5,
        ])
    }

    var contentSize: CGSize {
        let size = attributed.size()
        return CGSize(
            width: (size.width + horizontalPadding * 2).rounded(),
            height: (size.height + verticalPadding * 2).rounded()
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let cardRect = NSBezierPath(rect: bounds)
        let card = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)

        NSGraphicsContext.saveGraphicsState()
        card.addClip()

        // 1) Matte body: a low-contrast charcoal gradient. Flat and dark, not glossy. Angle -90 ⇒
        //    first colour on top; the small top-to-bottom delta is a soft diffuse shade, not a shine.
        let body = NSGradient(colorsAndLocations:
            (NSColor(white: 0.205, alpha: 0.98), 0.0),
            (NSColor(white: 0.165, alpha: 0.98), 0.5),
            (NSColor(white: 0.125, alpha: 0.98), 1.0)
        )
        body?.draw(in: bounds, angle: -90)

        // 2) Micro-grain: tile the cached noise to scatter the light — the matte texture.
        NSColor(patternImage: Self.grain).setFill()
        cardRect.fill()

        // 3) A whisper of diffuse light at the very top (no hard band) so it isn't dead flat.
        let topLight = NSGradient(colorsAndLocations:
            (NSColor(white: 1.0, alpha: 0.05), 1.0),
            (NSColor(white: 1.0, alpha: 0.0), 0.0)
        )
        topLight?.draw(in: CGRect(x: 0, y: bounds.height * 0.6, width: bounds.width, height: bounds.height * 0.4), angle: -90)

        NSGraphicsContext.restoreGraphicsState()

        let glyphs = textPath()

        // 4) Emboss: a soft dark copy nudged down 1px reads as engraving into the matte surface.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -1)
        ctx.addPath(glyphs)
        ctx.clip()
        NSColor(white: 0.0, alpha: 0.5).setFill()
        ctx.fill(bounds)
        ctx.restoreGState()

        // 5) Satin lettering: a gentle, low-contrast grey gradient — brushed, not chromed.
        ctx.saveGState()
        ctx.addPath(glyphs)
        ctx.clip()
        let satinText = NSGradient(colorsAndLocations:
            (NSColor(white: 0.86, alpha: 1.0), 0.0),
            (NSColor(white: 0.74, alpha: 1.0), 0.5),
            (NSColor(white: 0.62, alpha: 1.0), 1.0)
        )
        satinText?.draw(in: glyphs.boundingBoxOfPath, angle: -90)
        ctx.restoreGState()
    }

    /// Build the reusable grain tile: mostly transparent, with sparse faint light and dark specks.
    /// Kept very low-alpha so it texturises the surface without looking noisy.
    private static func makeGrain(side: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4, bitsPerPixel: 32
        ) else { return image }

        for y in 0..<side {
            for x in 0..<side {
                let roll = Double.random(in: 0...1)
                let colour: NSColor
                if roll < 0.5 {
                    colour = NSColor(white: 1.0, alpha: CGFloat.random(in: 0...0.04)) // faint highlight
                } else {
                    colour = NSColor(white: 0.0, alpha: CGFloat.random(in: 0...0.05)) // faint pit
                }
                rep.setColor(colour, atX: x, y: y)
            }
        }
        image.addRepresentation(rep)
        return image
    }

    /// The combined outline of the (centred) uppercase text as a CGPath, for clipping a gradient fill.
    private func textPath() -> CGPath {
        let attr = attributed
        let line = CTLineCreateWithAttributedString(attr)
        let result = CGMutablePath()

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let textSize = attr.size()
        let originX = (bounds.width - textSize.width) / 2
        let baselineY = (bounds.height - (ascent + descent)) / 2 + descent

        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let ctFont = attrs[kCTFontAttributeName as String] else { continue }
            let font = ctFont as! CTFont
            let count = CTRunGetGlyphCount(run)
            for i in 0..<count {
                let range = CFRangeMake(i, 1)
                var glyph = CGGlyph()
                var position = CGPoint()
                CTRunGetGlyphs(run, range, &glyph)
                CTRunGetPositions(run, range, &position)
                guard let glyphPath = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                let transform = CGAffineTransform(translationX: originX + position.x, y: baselineY + position.y)
                result.addPath(glyphPath, transform: transform)
            }
        }
        return result
    }
}
