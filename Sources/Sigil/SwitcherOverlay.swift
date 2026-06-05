import AppKit

/// Owns the centered, click-through palette that shows the switcher query and numbered results.
/// Like the hint overlay it never becomes key — typing is captured by the global `InputTap`.
final class SwitcherOverlayController {
    private var window: NSWindow?
    private var view: SwitcherView?

    func show(query: String, results: [WindowEntry]) {
        let window = ensureWindow()
        view?.update(query: query, results: results)
        view?.startCaret()
        position(window)
        window.orderFrontRegardless()
    }

    func hide() {
        view?.stopCaret()
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

        let view = SwitcherView(frame: .zero)
        panel.contentView = view

        self.window = panel
        self.view = view
        return panel
    }

    /// Centre horizontally, biased toward the upper third of the active screen (Spotlight-like).
    private func position(_ window: NSWindow) {
        guard let view, let screen = NSScreen.main else { return }
        let size = view.contentSize
        let area = screen.visibleFrame
        let origin = CGPoint(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2 + area.height * 0.18
        )
        window.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

/// Draws the switcher palette: a rounded card with the live query on top and the numbered
/// result rows below.
final class SwitcherView: NSView {
    private var query = ""
    private var results: [WindowEntry] = []
    private var caretOn = true
    private var caretTimer: Timer?

    private let cardWidth: CGFloat = 580
    private let headerHeight: CGFloat = 44
    private let rowHeight: CGFloat = 32
    private let padding: CGFloat = 14
    private let maxTitleChars = 64

    private let queryFont = NSFont.systemFont(ofSize: 18, weight: .medium)
    private let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private let appFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    private let badgeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    /// Size the card to fit the current rows.
    var contentSize: CGSize {
        let rows = max(results.count, 1)
        let height = padding + headerHeight + CGFloat(rows) * rowHeight + padding
        return CGSize(width: cardWidth, height: height)
    }

    func update(query: String, results: [WindowEntry]) {
        self.query = query
        self.results = results
        caretOn = true
        needsDisplay = true
    }

    /// Begin (or restart) the caret blink while the palette is visible.
    func startCaret() {
        caretOn = true
        caretTimer?.invalidate()
        caretTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.caretOn.toggle()
            self.needsDisplay = true
        }
        needsDisplay = true
    }

    func stopCaret() {
        caretTimer?.invalidate()
        caretTimer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let textColor = isDark ? NSColor.white : NSColor.black
        let dimColor = isDark ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0, alpha: 0.5)
        let lineColor = isDark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1)

        let card = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        (isDark ? NSColor(white: 0.13, alpha: 0.98) : NSColor(white: 0.97, alpha: 0.98)).setFill()
        card.fill()
        (isDark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.12)).setStroke()
        card.lineWidth = 1
        card.stroke()

        // Header: the live query with a trailing caret, or a placeholder. Placeholder and typed
        // text share the same origin so the text doesn't shift when typing begins.
        let headerY = bounds.height - padding - 26
        let textX = padding + 6
        if query.isEmpty {
            NSAttributedString(string: "Type to search windows…", attributes: [
                .font: queryFont,
                .foregroundColor: dimColor,
            ]).draw(at: CGPoint(x: textX, y: headerY))
            if caretOn { drawCaret(atX: textX, baselineY: headerY, color: textColor) }
        } else {
            let attr = NSAttributedString(string: query, attributes: [
                .font: queryFont,
                .foregroundColor: textColor,
            ])
            attr.draw(at: CGPoint(x: textX, y: headerY))
            if caretOn { drawCaret(atX: textX + attr.size().width + 2, baselineY: headerY, color: textColor) }
        }

        let separatorY = bounds.height - padding - headerHeight
        let separator = NSBezierPath()
        separator.move(to: CGPoint(x: padding, y: separatorY))
        separator.line(to: CGPoint(x: bounds.width - padding, y: separatorY))
        lineColor.setStroke()
        separator.lineWidth = 1
        separator.stroke()

        guard !results.isEmpty else {
            NSAttributedString(string: "No matching windows", attributes: [
                .font: appFont,
                .foregroundColor: dimColor,
            ]).draw(at: CGPoint(x: padding + 6, y: separatorY - rowHeight + 9))
            return
        }

        for (index, entry) in results.enumerated() {
            let rowBottom = separatorY - CGFloat(index + 1) * rowHeight

            NSAttributedString(string: "\(index + 1)", attributes: [
                .font: badgeFont,
                .foregroundColor: dimColor,
            ]).draw(at: CGPoint(x: padding + 8, y: rowBottom + (rowHeight - 14) / 2))

            let titleX = padding + 32
            let title = truncate(entry.displayTitle)
            let titleAttr = NSAttributedString(string: title, attributes: [
                .font: titleFont,
                .foregroundColor: textColor,
            ])
            titleAttr.draw(at: CGPoint(x: titleX, y: rowBottom + (rowHeight - 17) / 2))

            // Show the app name beside the title only when the title isn't already the app name.
            if !entry.title.isEmpty {
                NSAttributedString(string: "   —   \(entry.appName)", attributes: [
                    .font: appFont,
                    .foregroundColor: dimColor,
                ]).draw(at: CGPoint(x: titleX + titleAttr.size().width, y: rowBottom + (rowHeight - 14) / 2))
            }
        }
    }

    private func drawCaret(atX x: CGFloat, baselineY y: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(rect: NSRect(x: x, y: y + 1, width: 2, height: 21)).fill()
    }

    private func truncate(_ text: String) -> String {
        guard text.count > maxTitleChars else { return text }
        return String(text.prefix(maxTitleChars - 1)) + "…"
    }
}
