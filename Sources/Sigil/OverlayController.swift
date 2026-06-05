import AppKit

/// Owns the borderless, click-through, always-on-top window that renders hint labels across
/// all displays. The window never becomes key or activates Sigil, so the underlying app keeps
/// its focus; key capture happens entirely through the `InputTap`.
final class OverlayController {
    private var window: NSWindow?
    private var overlayView: OverlayView?

    func show(boxes: [HintBox], geometry: Geometry, typedPrefix: String) {
        let frame = geometry.unionCocoaFrame
        let window = ensureWindow(frame: frame)

        overlayView?.update(
            boxes: boxes,
            originOffset: frame.origin,
            typedPrefix: typedPrefix
        )
        window.orderFrontRegardless()
    }

    func updatePrefix(_ prefix: String, boxes: [HintBox], geometry: Geometry) {
        overlayView?.update(
            boxes: boxes,
            originOffset: geometry.unionCocoaFrame.origin,
            typedPrefix: prefix
        )
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func ensureWindow(frame: CGRect) -> NSWindow {
        if let window {
            window.setFrame(frame, display: false)
            overlayView?.frame = CGRect(origin: .zero, size: frame.size)
            return window
        }

        let window = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = OverlayView(frame: CGRect(origin: .zero, size: frame.size))
        window.contentView = view

        self.window = window
        self.overlayView = view
        return window
    }
}
