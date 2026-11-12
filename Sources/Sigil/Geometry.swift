import AppKit
import CoreGraphics

/// Bridges between the two coordinate systems Sigil deals with:
///
/// - **Accessibility / Quartz global space**: origin at the top-left of the primary
///   display, y increases downward. Returned by `AXPosition`/`AXSize` and consumed by
///   `CGEvent` mouse posting.
/// - **Cocoa global space**: origin at the bottom-left of the primary display, y increases
///   upward. Used by `NSWindow`/`NSView`.
///
/// A snapshot is taken at hint-mode activation so positions stay consistent for the lifetime
/// of one overlay even if displays reconfigure mid-flight.
struct Geometry {
    /// Height of the primary display (the one owning the menu bar, anchored at origin).
    let primaryHeight: CGFloat
    /// Union of all displays in Cocoa global coordinates.
    let unionCocoaFrame: CGRect
    /// Union of all displays in Accessibility coordinates (used to cull off-screen elements).
    let axBounds: CGRect
    /// Every connected display, in `NSScreen.screens` order. The overlay draws one window per
    /// entry: with "Displays have separate Spaces" on, macOS relocates any window that spans
    /// displays, so a single union-sized window cannot be positioned reliably.
    let screens: [ScreenInfo]

    static func snapshot() -> Geometry {
        let nsScreens = NSScreen.screens
        let primaryHeight = nsScreens.first?.frame.height ?? 0

        let unionCocoa = nsScreens.reduce(CGRect.null) { $0.union($1.frame) }

        let screens = nsScreens.map { screen -> ScreenInfo in
            let f = screen.frame
            let axRect = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            return ScreenInfo(displayID: Self.displayID(of: screen), cocoaFrame: f, axFrame: axRect)
        }
        let axUnion = screens.reduce(CGRect.null) { $0.union($1.axFrame) }

        return Geometry(
            primaryHeight: primaryHeight,
            unionCocoaFrame: unionCocoa.isNull ? .zero : unionCocoa,
            axBounds: axUnion.isNull ? .zero : axUnion,
            screens: screens
        )
    }

    /// The Quartz display ID backing an `NSScreen`, stable across snapshots while the display
    /// stays connected (unlike the screen's array index or frame).
    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        return 0
    }

    /// Convert an Accessibility rect (top-left origin) to Cocoa global coordinates (bottom-left).
    func cocoaGlobalRect(fromAX ax: CGRect) -> CGRect {
        CGRect(
            x: ax.minX,
            y: primaryHeight - ax.maxY,
            width: ax.width,
            height: ax.height
        )
    }

    /// The display whose Cocoa frame contains a hint's anchor (an element's top-left corner).
    /// Containment is half-open to suit a top-left anchor: an anchor flush with a display's top
    /// edge (menu-bar items) belongs to that display, and an anchor exactly on the seam between
    /// two side-by-side displays belongs to the one on the right.
    func screen(containingCocoaAnchor point: CGPoint) -> ScreenInfo? {
        screens.first { screen in
            let f = screen.cocoaFrame
            return f.minX <= point.x && point.x < f.maxX && f.minY < point.y && point.y <= f.maxY
        }
    }

    /// Assign each hint box to the display it should be drawn on. A box goes to the display
    /// containing its top-left corner; failing that, to the display it overlaps most; a box that
    /// overlaps no display is dropped. Pure: depends only on this snapshot and the boxes.
    func route(_ boxes: [HintBox]) -> [CGDirectDisplayID: [HintBox]] {
        var routed: [CGDirectDisplayID: [HintBox]] = [:]
        for box in boxes {
            guard let screen = displayForBox(box) else { continue }
            routed[screen.displayID, default: []].append(box)
        }
        return routed
    }

    private func displayForBox(_ box: HintBox) -> ScreenInfo? {
        let anchor = CGPoint(x: box.cocoaRect.minX, y: box.cocoaRect.maxY)
        if let direct = screen(containingCocoaAnchor: anchor) { return direct }

        var best: ScreenInfo?
        var bestArea: CGFloat = 0
        for screen in screens {
            let overlap = box.cocoaRect.intersection(screen.cocoaFrame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }
}

/// One connected display as captured in a `Geometry` snapshot.
struct ScreenInfo: Equatable {
    let displayID: CGDirectDisplayID
    /// Display bounds in Cocoa global coordinates (bottom-left origin).
    let cocoaFrame: CGRect
    /// Display bounds in Accessibility coordinates (top-left origin).
    let axFrame: CGRect
}
