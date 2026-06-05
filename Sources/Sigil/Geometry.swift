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
    /// Union of all displays in Cocoa global coordinates (the overlay window frame).
    let unionCocoaFrame: CGRect
    /// Union of all displays in Accessibility coordinates (used to cull off-screen elements).
    let axBounds: CGRect

    static func snapshot() -> Geometry {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0

        let unionCocoa = screens.reduce(CGRect.null) { $0.union($1.frame) }

        // Convert each screen frame into AX space and union them.
        let axUnion = screens.reduce(CGRect.null) { partial, screen in
            let f = screen.frame
            let axRect = CGRect(
                x: f.minX,
                y: primaryHeight - f.maxY,
                width: f.width,
                height: f.height
            )
            return partial.union(axRect)
        }

        return Geometry(
            primaryHeight: primaryHeight,
            unionCocoaFrame: unionCocoa.isNull ? .zero : unionCocoa,
            axBounds: axUnion.isNull ? .zero : axUnion
        )
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
}
