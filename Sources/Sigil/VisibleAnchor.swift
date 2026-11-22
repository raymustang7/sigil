import ApplicationServices
import CoreGraphics

/// Finds where an element's visible area actually starts, so its hint lands on it.
///
/// Some apps report element frames that run underneath another part of their own UI: WhatsApp's
/// chat rows start 100pt under its left sidebar, so a hint at the reported top-left corner drew
/// over the sidebar instead of the row. Hit-testing the app at the left edge tells us whether
/// something else is on top there; if so, we step past that occluder and probe again.
enum VisibleAnchor {
    /// What the app reports at a probe point.
    enum Hit: Equatable {
        /// The element itself.
        case target
        /// Some other element, with its frame (AX coordinates).
        case element(CGRect)
        /// Hit-testing failed or returned an element without a frame.
        case unavailable
    }

    /// Hit tests per element, at most. Each is an IPC round trip to the app.
    static let maxProbes = 4
    /// How far inside the candidate edge each probe lands.
    private static let probeInset: CGFloat = 4
    /// Below this much remaining width, stop looking and keep the reported frame.
    private static let minVisibleWidth: CGFloat = 8

    /// The element's frame with its left edge moved past anything of the same app drawn over it.
    /// Never drops an element and never moves it outside its reported frame: whenever the probes
    /// are inconclusive, the reported frame comes back unchanged.
    static func visibleFrame(_ frame: CGRect, hitTest: (CGPoint) -> Hit) -> CGRect {
        var left = frame.minX
        for _ in 0..<maxProbes {
            guard frame.maxX - left >= minVisibleWidth else { return frame }
            let point = CGPoint(x: left + probeInset, y: frame.midY)
            switch hitTest(point) {
            case .target:
                return clipped(frame, left: left)
            case .unavailable:
                return frame
            case .element(let hit):
                // A child of the element (its label, icon) or a container it sits in: visible.
                if frame.insetBy(dx: -1, dy: -1).contains(hit) || hit.contains(frame.insetBy(dx: 1, dy: 1)) {
                    return clipped(frame, left: left)
                }
                // Something else is on top here; resume just past its right edge.
                guard hit.maxX > left else { return frame }
                left = hit.maxX
            }
        }
        return frame
    }

    private static func clipped(_ frame: CGRect, left: CGFloat) -> CGRect {
        left == frame.minX ? frame
            : CGRect(x: left, y: frame.minY, width: frame.maxX - left, height: frame.height)
    }

    /// Hit-tests `application` at `point` and classifies the answer relative to `element`.
    static func hit(_ application: AXUIElement, at point: CGPoint, for element: AXUIElement) -> Hit {
        var result: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &result) == .success,
              let result else { return .unavailable }
        if CFEqual(result, element) { return .target }
        guard let frame = AX.frame(result) else { return .unavailable }
        return .element(frame)
    }
}
