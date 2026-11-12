import AppKit

/// Owns the borderless, click-through, always-on-top windows that render hint labels: one per
/// connected display, each sized exactly to that display. The windows never become key or
/// activate Sigil, so the underlying app keeps its focus; key capture happens entirely through
/// the `InputTap`.
///
/// Why one window per display: with "Displays have separate Spaces" on (the macOS default) a
/// window belongs to a single display. A window spanning several displays is reassigned to one
/// of them by the window server about a second after it appears, and its origin is shifted by
/// that display's origin — so every hint drew offset, on one display only, with a visible jump.
/// A window that matches one display's frame exactly is never moved.
final class OverlayController {
    private struct ScreenPanel {
        let panel: NSPanel
        let view: OverlayView
    }

    /// Live panels keyed by Quartz display ID, reused across activations while the display
    /// stays connected.
    private var panels: [CGDirectDisplayID: ScreenPanel] = [:]

    func show(boxes: [HintBox], geometry: Geometry, typedPrefix: String) {
        guard !geometry.screens.isEmpty else {
            hide()
            return
        }

        let routed = geometry.route(boxes)

        // Displays that disappeared since the last activation lose their panel.
        let currentIDs = Set(geometry.screens.map(\.displayID))
        for (id, screenPanel) in panels where !currentIDs.contains(id) {
            screenPanel.panel.orderOut(nil)
            panels.removeValue(forKey: id)
        }

        // Every present display gets its panel refreshed — with an empty list when it has no
        // hints, so nothing stale lingers from a previous call.
        for screen in geometry.screens {
            let screenPanel = self.screenPanel(for: screen)
            screenPanel.view.update(
                boxes: routed[screen.displayID] ?? [],
                originOffset: screen.cocoaFrame.origin,
                typedPrefix: typedPrefix
            )
            screenPanel.panel.orderFrontRegardless()
        }

        let perDisplay = geometry.screens
            .map { "\($0.displayID):\(routed[$0.displayID]?.count ?? 0)" }
            .joined(separator: " ")
        Log.write("overlay: \(geometry.screens.count) displays, \(boxes.count) hints → \(perDisplay)")
    }

    /// Re-render with a new typed prefix. `boxes` and `geometry` are accepted for API
    /// compatibility; each panel already holds the boxes routed to it by `show`.
    func updatePrefix(_ prefix: String, boxes: [HintBox], geometry: Geometry) {
        for screenPanel in panels.values {
            screenPanel.view.setTypedPrefix(prefix)
        }
    }

    func hide() {
        for screenPanel in panels.values {
            screenPanel.panel.orderOut(nil)
        }
    }

    /// The panel for a display, created on first use and re-framed to the display's current
    /// bounds on every call (a display can move or change resolution between activations).
    private func screenPanel(for screen: ScreenInfo) -> ScreenPanel {
        let frame = screen.cocoaFrame
        if let existing = panels[screen.displayID] {
            if existing.panel.frame != frame {
                existing.panel.setFrame(frame, display: false)
                existing.view.frame = CGRect(origin: .zero, size: frame.size)
            }
            return existing
        }
        let created = makePanel(frame: frame)
        panels[screen.displayID] = created
        return created
    }

    private func makePanel(frame: CGRect) -> ScreenPanel {
        let panel = NSPanel(
            contentRect: frame,
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

        let view = OverlayView(frame: CGRect(origin: .zero, size: frame.size))
        panel.contentView = view
        return ScreenPanel(panel: panel, view: view)
    }
}
